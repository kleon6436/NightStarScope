import Foundation
import CoreLocation
import SwiftUI

/// 星空マップの設定と現在値を配信する依存関係。
@MainActor
struct StarMapSettingsDependency {
    let currentSettings: () -> StarMapDisplaySettings
    /// 設定の変化を流す列を作る。購読ごとに呼ぶ（AsyncStream は 1 つの購読先にしか配れないため）。
    /// 同じ値が続いても構わない（購読側で現在の設定と比べて読み飛ばす）。
    let changes: () -> any AsyncSequence<StarMapDisplaySettings, Never>

    static let live = StarMapSettingsDependency(
        currentSettings: {
            StarMapDisplaySettings.load()
        },
        // UserDefaults の変更通知は書き込んだスレッドで届くが、購読側は MainActor の Task で反復するため、
        // 設定の読み直しはメインで行われる。
        changes: {
            NotificationCenter.default.userDefaultsChanges().map { _ in StarMapDisplaySettings.load() }
        }
    )
}

/// 星空描画に必要なスナップショット計算の依存関係。
struct StarMapComputationDependency: Sendable {
    let computeSnapshot: @Sendable (
        _ latitude: Double,
        _ longitude: Double,
        _ julianDate: Double,
        _ localSiderealTime: Double,
        _ activeMeteorShowers: [MeteorShower],
        _ density: StarDisplayDensity
    ) async -> StarMapComputation.Snapshot

    static let live = StarMapComputationDependency(
        computeSnapshot: { latitude, longitude, julianDate, localSiderealTime, activeMeteorShowers, density in
            _ = await StarCatalog.preloadedStars()
            return await Task.detached(priority: .userInitiated) {
                StarMapComputation.compute(
                    latitude: latitude,
                    longitude: longitude,
                    julianDate: julianDate,
                    localSiderealTime: localSiderealTime,
                    activeMeteorShowers: activeMeteorShowers,
                    starDisplayDensity: density
                )
            }.value
        }
    )
}

/// 1 時刻ぶんの観測条件を記録する。
struct StarMapObservationConditionSample: Equatable {
    let moonAltitude: Double
    let moonPhase: Double
    let sunAltitude: Double
}

// MARK: - ViewModel

/// 星空マップの描画状態、観測日時、視点操作をまとめて管理する。
/// Observation で公開し、各ビューは実際に読んだプロパティの変化でのみ再描画される
/// （パン・ズーム・ジャイロのたびに詳細画面やサイドバー全体が再構築されるのを避ける）。
@MainActor
@Observable
final class StarMapViewModel {

    // MARK: - Celestial object positions

    private(set) var starField: StarMapComputation.StarField = .empty
    private(set) var sunAltitude: Double = 0
    private(set) var moonAltitude: Double = 0
    private(set) var moonAzimuth: Double = 0
    private(set) var moonPhase: Double = 0      // 0=新月, 0.5=満月, 1=新月
    /// 月の輝面の向き（天頂方向 0°、観測者から見て左回り, 度）。nil なら従来の左右表示
    private(set) var moonBrightLimbZenithAngle: Double? = nil
    private(set) var galacticCenterAltitude: Double = 0
    private(set) var galacticCenterAzimuth: Double = 0
    private(set) var constellationLines: [ConstellationLineSegment] = []
    private(set) var constellationLabels: [ConstellationLabelAltAz] = []
    private(set) var planetPositions: [PlanetPosition] = []
    private(set) var meteorShowerRadiants: [(shower: MeteorShower, altitude: Double, azimuth: Double)] = []
    private(set) var terrainProfile: TerrainProfile? = nil
    private(set) var terrainFetchState: StarMapTerrainFetchState = .idle
    private(set) var showsConstellationLines: Bool = StarMapDisplaySettings.defaultValue.showsConstellationLines
    private(set) var showsConstellationLabels: Bool = StarMapDisplaySettings.defaultValue.showsConstellationLabels
    private(set) var showsPlanets: Bool = StarMapDisplaySettings.defaultValue.showsPlanets
    private(set) var showsMeteorShowers: Bool = StarMapDisplaySettings.defaultValue.showsMeteorShowers
    private(set) var showsMilkyWay: Bool = StarMapDisplaySettings.defaultValue.showsMilkyWay
    /// 天の川バンドのキャッシュ (lat/LST が変わったときのみ再計算)
    private(set) var milkyWayBandPoints: [MilkyWayBandPoint] = []
    private(set) var observationConditionTimeline: [StarMapObservationConditionSample] = []

    // MARK: - Observation datetime (independent of AppController.selectedDate)

    var displayDate: Date = Date() {
        didSet {
            handleDisplayDateChange(from: oldValue, to: displayDate)
        }
    }

    private(set) var timeSliderMinutes: Double = 0
    private(set) var isTimeSliderScrubbing: Bool = false

    /// 夜間開始時刻 (分, 0-1439) — 日没 (太陽高度 0°) 基準
    private(set) var nightStartMinutes: Double = 1080  // デフォルト 18:00
    /// 夜間の長さ (分)
    private(set) var nightDurationMinutes: Double = 600 // デフォルト 10時間

    // MARK: - View direction (full-sky planisphere rotation or gyro center)

    /// 画面中心が向く方位角 (度, 0=北, 時計回り)。パノラマモードでは中央の方位
    var viewAzimuth: Double = 0   // 初期値=北向き

    /// 画面中心の仰角 (度, 0=地平線, 90=天頂)。ジャイロモードで使用
    var viewAltitude: Double = 45

    /// 画面のロール角 (度)。ジャイロモード時のみ投影へ反映する
    var viewRoll: Double = 0

    /// ジャイロモードの有効/無効 (iPhone のみ true にする)
    var isGyroMode: Bool = false

    /// 水平視野角 (度): 30°〜150°, デフォルト 60°
    var fov: Double = StarMapLayout.defaultFOV

    /// 星空マップ描画領域の最新サイズ
    private(set) var canvasSize: CGSize = .zero

    /// 星空マップシートが表示中か（サイドバーの視野オーバーレイ連動用）
    var isStarMapOpen: Bool = false

    /// 現在の視野方向（サイドバーマップオーバーレイ用）
    var viewingDirection: ViewingDirection {
        ViewingDirection(azimuth: viewAzimuth, fov: fov, isActive: isStarMapOpen)
    }

    // MARK: - Dependencies

    @ObservationIgnored private let appController: AppController
    @ObservationIgnored private let settingsDependency: StarMapSettingsDependency
    @ObservationIgnored private let terrainCoordinator: StarMapTerrainCoordinator
    /// スライダー編集中の日時コミット間隔: 20fps
    @ObservationIgnored private let timeSliderScheduler = StarMapTimeSliderScheduler(commitInterval: 1.0 / 20)
    @ObservationIgnored private let computationDependency: StarMapComputationDependency
    /// 地点・タイムゾーンの変化を受け取るタスク。
    @ObservationIgnored private var selectionObservationTask: Task<Void, Never>?
    /// 表示設定の変化を受け取るタスク。
    @ObservationIgnored private var settingsObservationTask: Task<Void, Never>?
    /// AppController の選択日の変化を受け取るタスク。
    @ObservationIgnored private var selectedDateObservationTask: Task<Void, Never>?
    @ObservationIgnored private var shouldApplyInitialPose = true
    @ObservationIgnored private var hasPreparedInitialPresentation = false
    @ObservationIgnored private var displayDateUpdateMode: DisplayDateUpdateMode = .standard
    /// 表示設定は `displaySettings` 経由でビューが読むため追跡対象に残す。
    private var starMapDisplaySettings: StarMapDisplaySettings
    @ObservationIgnored private var starDisplayDensity: StarDisplayDensity
    /// 星座ラベル配置の最終計算結果キャッシュ（視点が変化していなければ再計算をスキップする）
    /// body 評価中に書き換えるため、追跡すると再描画ループになる。
    @ObservationIgnored private var cachedLabelPlacements: (key: LabelPlacementCacheKey, value: [ConstellationLabelPlacement])?
    /// 前フレームの星座ラベル候補（視点が止まったかの判定用）。body 評価中に書き換えるため追跡しない。
    @ObservationIgnored private var lastLabelCandidates: [ConstellationLabelCandidate]?
    /// 最後に配置を最適化した時刻。ジャイロの微小な揺れで「動いている」状態が続いても、
    /// 一定時間ごとに配置し直して重なりが残り続けないようにする。
    @ObservationIgnored private var lastLabelLayoutTime: ContinuousClock.Instant?
    /// 夜間タイムラインの最終計算結果キャッシュ（入力が変化していなければ再計算をスキップする）
    @ObservationIgnored private var cachedObservationTimeline: (key: TimelineCacheKey, value: [StarMapObservationConditionSample])?
    /// 次の流星群のキャッシュ。結果は観測地タイムゾーンでの暦日だけで決まるため、その日の範囲で使い回す。
    /// body 評価中に書き換えるため追跡しない。
    @ObservationIgnored private var cachedNextMeteorShower: (
        dayInterval: DateInterval,
        timeZoneIdentifier: String,
        value: (shower: MeteorShower, daysUntilPeak: Int)?
    )?
    /// AppController 側の観測日・地点（Observation 非対応）が変わったことをビューへ伝えるためのカウンタ。
    /// `observationDate` などの派生プロパティが読むことで、ビューの追跡対象に入る。
    private var observationContextRevision = 0

    // MARK: - Init

    init(
        appController: AppController,
        settingsDependency: StarMapSettingsDependency? = nil,
        terrainDependency: StarMapTerrainDependency? = nil,
        computationDependency: StarMapComputationDependency? = nil
    ) {
        let resolvedSettingsDependency = settingsDependency ?? .live
        let initialDisplaySettings = resolvedSettingsDependency.currentSettings()
        self.appController = appController
        self.settingsDependency = resolvedSettingsDependency
        self.terrainCoordinator = StarMapTerrainCoordinator(dependency: terrainDependency ?? .live)
        self.computationDependency = computationDependency ?? .live
        self.starMapDisplaySettings = initialDisplaySettings
        self.starDisplayDensity = initialDisplaySettings.density
        self.showsConstellationLines = initialDisplaySettings.showsConstellationLines
        self.showsConstellationLabels = initialDisplaySettings.showsConstellationLabels
        self.showsPlanets = initialDisplaySettings.showsPlanets
        self.showsMeteorShowers = initialDisplaySettings.showsMeteorShowers
        self.showsMilkyWay = initialDisplaySettings.showsMilkyWay
        setupBindings()
        updateNightRange(referenceDate: displayDate)
        syncTimeSliderWithDisplayDate()
    }

    deinit {
        updateTask?.cancel()
        trailingTask?.cancel()
        selectionObservationTask?.cancel()
        settingsObservationTask?.cancel()
        selectedDateObservationTask?.cancel()
    }

    // MARK: - Calculation

    /// 進行中の計算タスク (新しい update() 呼び出しでキャンセルする)
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    /// trailing-edge debounce 用タスク
    @ObservationIgnored private var trailingTask: Task<Void, Never>?
    /// 前回の計算開始タイムスタンプ (全 update() 呼び出しで共通スロットルに使用)
    @ObservationIgnored private var lastPositionUpdateTime: TimeInterval = 0
    /// 通常時の計算更新インターバル: 30fps
    private static let minUpdateInterval: TimeInterval = 1.0 / 30
    /// スライダー編集中の計算更新インターバル: 20fps
    private static let minScrubbingUpdateInterval: TimeInterval = 1.0 / 20
    private struct UpdateContext {
        let latitude: Double
        let longitude: Double
        let julianDate: Double
        let localSiderealTime: Double
        let activeMeteorShowers: [MeteorShower]

        var terrainCacheKey: String {
            StarMapViewModel.terrainCacheKey(latitude: latitude, longitude: longitude)
        }
    }

    private struct ObservationContext {
        let selectedDate: Date
        let location: CLLocationCoordinate2D
        let timeZone: TimeZone
    }

    private struct LabelPlacementCacheKey: Equatable {
        let candidates: [ConstellationLabelCandidate]
        let canvasSize: CGSize
        let reservedBottomInset: Double
    }

    private struct TimelineCacheKey: Equatable {
        let latitude: Double
        let longitude: Double
        let observationDate: Date
        let timeZoneIdentifier: String
        let nightStartMinutes: Double
        let nightDurationMinutes: Double
    }

    private enum DisplayDateUpdateMode {
        case standard
        case preserveNightRangeAndSlider

        var skipsTimeSliderSync: Bool {
            self == .preserveNightRangeAndSlider
        }
    }

    func update() {
        // VM はアプリ起動時から常駐するため、星図が実際に表示されるまで初回計算を保留する。
        guard hasPreparedInitialPresentation else { return }

        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastPositionUpdateTime
        let minUpdateInterval = currentMinUpdateInterval

        if elapsed < minUpdateInterval {
            // 前回から時間が短い → trailing-edge debounce でインターバル後に最終値を計算
            trailingTask?.cancel()
            // 飛行中の計算はここではキャンセルしない。連続操作中に毎回破棄すると、
            // 操作が止まるまで一度もスナップショットが適用されず星図が固まる。
            let remaining = minUpdateInterval - elapsed
            trailingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.executeUpdate()
            }
            return
        }
        executeUpdate()
    }

    private func executeUpdate() {
        lastPositionUpdateTime = Date.timeIntervalSinceReferenceDate
        trailingTask?.cancel()
        trailingTask = nil

        let context = makeUpdateContext()
        scheduleTerrainFetchIfNeeded(for: context)

        // 前の計算タスクをキャンセルして新しいタスクを開始
        updateTask?.cancel()
        let density = starDisplayDensity
        updateTask = Task { [weak self] in
            guard let self else { return }

            let snapshot = await computationDependency.computeSnapshot(
                context.latitude,
                context.longitude,
                context.julianDate,
                context.localSiderealTime,
                context.activeMeteorShowers,
                density
            )

            guard !Task.isCancelled else { return }
            apply(snapshot)
        }
    }

    private var selectedLocation: CLLocationCoordinate2D {
        appController.locationController.selectedLocation
    }

    private var selectedTimeZone: TimeZone {
        appController.locationController.selectedTimeZone
    }

    private var observationContext: ObservationContext {
        ObservationContext(
            selectedDate: appController.selectedDate,
            location: selectedLocation,
            timeZone: selectedTimeZone
        )
    }

    private func setupBindings() {
        // 地点とタイムゾーンは同時に変わることが多い。Observations は同じ実行中の変更をまとめ、
        // 書き込み後の値で 1 回だけ流すため、確定後に 1 回だけ再同期できる。
        // 購読開始時の値も流れるため、開始時点の値と比べて変わったときだけ扱う（旧 dropFirst）。
        // LocationController は座標が変わったときだけ selectedLocation を書き換えるため、比較で取りこぼす変更はない。
        let locationController = appController.locationController
        let initialSelection = (
            location: locationController.selectedLocation,
            timeZoneIdentifier: locationController.selectedTimeZone.identifier
        )
        let selectionChanges = Observations {
            (
                location: locationController.selectedLocation,
                timeZoneIdentifier: locationController.selectedTimeZone.identifier
            )
        }
        selectionObservationTask = Task { [weak self] in
            var lastSelection = initialSelection
            for await selection in selectionChanges {
                guard let self else { return }
                guard selection.location.latitude != lastSelection.location.latitude
                    || selection.location.longitude != lastSelection.location.longitude
                    || selection.timeZoneIdentifier != lastSelection.timeZoneIdentifier else { continue }
                lastSelection = selection
                self.observationContextRevision += 1
                self.resyncAfterSelectionChange()
            }
        }

        let settingsChanges = settingsDependency.changes()
        settingsObservationTask = Task { [weak self] in
            for await settings in settingsChanges {
                guard let self else { return }
                self.applyStarMapDisplaySettings(settings)
            }
        }

        // 旧実装も receive(on: DispatchQueue.main) で次のターンに処理していたため、Observations の遅れは挙動を変えない。
        // 星図の再同期は表示用で、同じ実行中に続く処理が読む状態は持たない。
        // 購読開始時の値も流れるため、最後に扱った選択日と比べて変わったときだけ扱う（旧 dropFirst + removeDuplicates）。
        let appController = appController
        let initialSelectedDate = appController.selectedDate
        let selectedDateChanges = Observations { appController.selectedDate }
        selectedDateObservationTask = Task { [weak self] in
            var lastSelectedDate = initialSelectedDate
            for await selectedDate in selectedDateChanges where selectedDate != lastSelectedDate {
                guard let self else { return }
                lastSelectedDate = selectedDate
                self.observationContextRevision += 1
                self.handleSelectedDateChanged()
            }
        }
    }

    private func makeUpdateContext() -> UpdateContext {
        let context = observationContext
        let date = displayDate
        let julianDate = MilkyWayCalculator.julianDate(from: date)

        return UpdateContext(
            latitude: context.location.latitude,
            longitude: context.location.longitude,
            julianDate: julianDate,
            localSiderealTime: MilkyWayCalculator.localSiderealTime(
                jd: julianDate,
                longitude: context.location.longitude
            ),
            activeMeteorShowers: MeteorShowerCatalog.active(
                on: date,
                timeZone: context.timeZone
            )
        )
    }

    /// 表示する恒星密度を切り替え、必要な再計算を要求します。
    func setStarDisplayDensity(_ density: StarDisplayDensity) {
        applyStarMapDisplaySettings(
            StarMapDisplaySettings(
                density: density,
                showsConstellationLines: starMapDisplaySettings.showsConstellationLines,
                showsConstellationLabels: starMapDisplaySettings.showsConstellationLabels,
                showsPlanets: starMapDisplaySettings.showsPlanets,
                showsMeteorShowers: starMapDisplaySettings.showsMeteorShowers,
                showsMilkyWay: starMapDisplaySettings.showsMilkyWay
            )
        )
    }

    /// 星座線表示を切り替えます。
    func setShowsConstellationLines(_ showsConstellationLines: Bool) {
        applyStarMapDisplaySettings(
            StarMapDisplaySettings(
                density: starMapDisplaySettings.density,
                showsConstellationLines: showsConstellationLines,
                showsConstellationLabels: starMapDisplaySettings.showsConstellationLabels,
                showsPlanets: starMapDisplaySettings.showsPlanets,
                showsMeteorShowers: starMapDisplaySettings.showsMeteorShowers,
                showsMilkyWay: starMapDisplaySettings.showsMilkyWay
            )
        )
    }

    var displaySettings: StarMapDisplaySettings {
        starMapDisplaySettings
    }

    private func applyStarMapDisplaySettings(_ settings: StarMapDisplaySettings) {
        guard settings != starMapDisplaySettings else { return }

        let densityChanged = settings.density != starMapDisplaySettings.density

        starMapDisplaySettings = settings
        starDisplayDensity = settings.density
        showsConstellationLines = settings.showsConstellationLines
        showsConstellationLabels = settings.showsConstellationLabels
        showsPlanets = settings.showsPlanets
        showsMeteorShowers = settings.showsMeteorShowers
        showsMilkyWay = settings.showsMilkyWay

        if densityChanged {
            update()
        }
    }

    private func scheduleTerrainFetchIfNeeded(for context: UpdateContext) {
        terrainCoordinator.scheduleFetchIfNeeded(
            latitude: context.latitude,
            longitude: context.longitude,
            cacheKey: context.terrainCacheKey
        ) { [weak self] profile, state in
            self?.terrainProfile = profile
            self?.terrainFetchState = state
        }
    }

    private func apply(_ snapshot: StarMapComputation.Snapshot) {
        starField = snapshot.starField
        sunAltitude = snapshot.sunAltitude
        moonAltitude = snapshot.moonAltitude
        moonAzimuth = snapshot.moonAzimuth
        moonPhase = snapshot.moonPhase
        moonBrightLimbZenithAngle = snapshot.moonBrightLimbZenithAngle
        galacticCenterAltitude = snapshot.galacticCenterAltitude
        galacticCenterAzimuth = snapshot.galacticCenterAzimuth
        constellationLines = snapshot.constellationLines
        constellationLabels = snapshot.constellationLabels
        planetPositions = snapshot.planetPositions
        meteorShowerRadiants = snapshot.meteorShowerRadiants
        milkyWayBandPoints = snapshot.milkyWayBandPoints
    }

    // MARK: - Meteor Showers

    /// 現在の表示日時でアクティブな流星群
    var activeMeteorShowers: [MeteorShower] {
        _ = observationContextRevision
        return MeteorShowerCatalog.active(
            on: displayDate,
            timeZone: selectedTimeZone
        )
    }

    /// 次の流星群とピークまでの日数。表示日時の暦日が変わるまでキャッシュを返す。
    var nextMeteorShower: (shower: MeteorShower, daysUntilPeak: Int)? {
        _ = observationContextRevision
        let date = displayDate
        let timeZone = selectedTimeZone
        if let cached = cachedNextMeteorShower,
           cached.timeZoneIdentifier == timeZone.identifier,
           cached.dayInterval.start <= date, date < cached.dayInterval.end {
            return cached.value
        }
        let value = MeteorShowerCatalog.next(after: date, timeZone: timeZone)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        if let dayInterval = calendar.dateInterval(of: .day, for: date) {
            cachedNextMeteorShower = (dayInterval, timeZone.identifier, value)
        }
        return value
    }

    /// 現在の表示が属する観測日の開始時刻です。
    var observationDate: Date {
        _ = observationContextRevision
        return ObservationTimeZone.startOfDay(
            for: appController.selectedDate,
            timeZone: selectedTimeZone
        )
    }

    /// 観測日の暦日を判定する観測地のタイムゾーンです。日付ピッカー等の表示に使います。
    var observationTimeZone: TimeZone {
        _ = observationContextRevision
        return selectedTimeZone
    }

    /// 太陽が地平線下 (夜間) か
    var isNight: Bool { sunAltitude < 0 }

    /// 現在の観測日と時刻にリセット
    /// 日付が変わった後でも前夜の日の出前であれば前日を観測日とし、表示日時を現在時刻そのものに合わせる。
    func resetToNow(referenceDate: Date = Date()) {
        let context = observationContext
        let currentObservationDate = Self.currentObservationDate(
            for: referenceDate,
            location: context.location,
            timeZone: context.timeZone
        )
        appController.selectObservationDate(currentObservationDate, timeZone: context.timeZone)
        syncDisplayDate(referenceDate: referenceDate)
    }

    /// 現在時刻が属する観測日（夜の始まる日）を返す。定義は `StarMapDateLogic.currentObservationDate` に一本化している。
    nonisolated static func currentObservationDate(
        for now: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> Date {
        StarMapDateLogic.currentObservationDate(for: now, location: location, timeZone: timeZone)
    }

    /// 表示中の夜時刻をできるだけ保ったまま観測日を切り替えます。
    func setObservationDate(_ date: Date) {
        let timeZone = selectedTimeZone
        let normalizedDate = ObservationTimeZone.startOfDay(for: date, timeZone: timeZone)
        guard !ObservationTimeZone.isDate(
            appController.selectedDate,
            inSameDayAs: normalizedDate,
            timeZone: timeZone
        ) else {
            return
        }
        appController.selectObservationDate(normalizedDate, timeZone: timeZone)
        syncDisplayDate(referenceDate: displayDate)
    }

    /// 星空マップ表示に入る直前に、初期表示位置の再適用を要求する。
    func prepareForStarMapPresentation() {
        guard !hasPreparedInitialPresentation else { return }
        hasPreparedInitialPresentation = true
        shouldApplyInitialPose = true
    }

    /// 星空マップの初回表示に必要な初期化を一度だけ実行する。
    func activatePresentationIfNeeded(referenceDate: Date = Date()) {
        guard !hasPreparedInitialPresentation else { return }
        prepareForStarMapPresentation()
        if !syncWithSelectedDate(referenceDate: referenceDate) {
            update()
        }
    }

    /// 星空マップが表示されるたびに呼ぶ。初回は初期化し、2 回目以降は
    /// 非表示中の地点変更などを反映するため、表示時刻を保ったまま再同期・再計算する。
    func refreshPresentationOnAppear(referenceDate: Date = Date()) {
        guard hasPreparedInitialPresentation else {
            activatePresentationIfNeeded(referenceDate: referenceDate)
            return
        }
        resyncAfterSelectionChange()
    }

    /// 星空マップ描画領域の最新サイズを記録する。
    func updateCanvasSize(_ size: CGSize) {
        guard canvasSize != size else { return }
        canvasSize = size
    }

    /// 初回表示時に、デフォルト視点（北向き 仰角45°）を適用する。
    func applyInitialPoseIfNeeded() {
        guard shouldApplyInitialPose else { return }
        viewAzimuth = 0
        viewAltitude = StarMapLayout.resetAltitude
        viewRoll = 0
        shouldApplyInitialPose = false
    }

    /// ジャイロの姿勢をまとめて反映する。変化した値だけ書き込む（同値の代入は Observation も通知しない）。
    func applyGyroPose(azimuth: Double, altitude: Double, roll: Double) {
        if viewAzimuth != azimuth { viewAzimuth = azimuth }
        if viewAltitude != altitude { viewAltitude = altitude }
        if viewRoll != roll { viewRoll = roll }
    }

    /// 北向きへ戻す。
    func resetToNorth() {
        viewAzimuth = 0
        viewAltitude = StarMapLayout.resetAltitude
        viewRoll = 0
    }

    /// 選択日へ現在の時刻を反映し、表示日時を変更した場合は true を返す。
    /// `referenceDate` は現在時刻として扱う。
    /// - Note: アプリ全体の「今日」は AppController が観測日（深夜〜明け方は前日の夜）で選ぶため、
    ///   ここでは選択日を書き換えない。深夜に暦日の「今日」が選ばれているのは利用者が明夜を選んだ場合に限られる。
    @discardableResult
    func syncWithSelectedDate(referenceDate: Date = Date()) -> Bool {
        syncDisplayDate(referenceDate: referenceDate)
    }

    /// 選択日へ参照時刻の時刻を反映し、表示日時を変更した場合は true を返す。
    @discardableResult
    private func syncDisplayDate(referenceDate: Date) -> Bool {
        let context = observationContext
        updateNightRange(referenceDate: referenceDate)
        guard let date = resolvedPresentationDate(
            for: context.selectedDate,
            referenceDate: referenceDate,
            location: context.location,
            timeZone: context.timeZone
        ) else {
            return false
        }
        guard displayDate != date else {
            return false
        }
        displayDate = date
        return true
    }

    /// 夜間スライダーの値を表示日時へ反映します。
    func setTimeSliderMinutes(_ minutes: Double) {
        let clampedMinutes = max(0, min(timeSliderMaximumMinutes, minutes.rounded()))
        guard abs(timeSliderMinutes - clampedMinutes) > 0.5 else { return }
        timeSliderMinutes = clampedMinutes

        guard let updatedDate = makeDisplayDate(forTimeSliderMinutes: clampedMinutes) else {
            return
        }

        if isTimeSliderScrubbing {
            timeSliderScheduler.schedulePendingCommit(date: updatedDate) { [weak self] date in
                self?.setDisplayDate(
                    date,
                    mode: .preserveNightRangeAndSlider
                )
            }
        } else {
            setDisplayDate(
                updatedDate,
                mode: .preserveNightRangeAndSlider
            )
        }
    }

    /// 夜間スライダーに対応する表示用時刻文字列です。
    var displayTimeString: String {
        let realMinutes = StarMapDateLogic.nightOffsetToRealMinutes(
            timeSliderMinutes,
            nightStartMinutes: nightStartMinutes
        )
        return StarMapPresentation.timeString(from: realMinutes)
    }

    var timeSliderMaximumMinutes: Double {
        StarMapDateLogic.maxSelectableNightOffset(nightDurationMinutes: nightDurationMinutes)
    }

    var timeSliderFraction: Double {
        let maximumMinutes = timeSliderMaximumMinutes
        guard maximumMinutes > 0 else { return 0 }
        return max(0, min(1, timeSliderMinutes / maximumMinutes))
    }

    private func syncTimeSliderWithDisplayDate() {
        let context = observationContext
        let realMinutes = StarMapDateLogic.clockMinutes(
            for: displayDate,
            timeZone: context.timeZone
        )
        let offset = StarMapDateLogic.realMinutesToNightOffset(
            realMinutes,
            nightStartMinutes: nightStartMinutes,
            nightDurationMinutes: nightDurationMinutes
        )
        guard abs(timeSliderMinutes - offset) > 0.5 else { return }
        timeSliderMinutes = offset
    }

    /// スライダー編集中の更新頻度へ切り替えます。
    func beginTimeSliderInteraction() {
        guard !isTimeSliderScrubbing else { return }
        isTimeSliderScrubbing = true
    }

    /// 保留中の日時反映をコミットして通常更新へ戻します。
    func endTimeSliderInteraction() {
        guard isTimeSliderScrubbing else { return }
        isTimeSliderScrubbing = false
        timeSliderScheduler.flushPendingCommit { [weak self] date in
            self?.setDisplayDate(
                date,
                mode: .preserveNightRangeAndSlider
            )
        }
    }

    func finalizeTransientInteractionState() {
        if isTimeSliderScrubbing {
            endTimeSliderInteraction()
        } else {
            timeSliderScheduler.flushPendingCommit { [weak self] date in
                self?.setDisplayDate(
                    date,
                    mode: .preserveNightRangeAndSlider
                )
            }
        }
    }

    private var currentMinUpdateInterval: TimeInterval {
        isTimeSliderScrubbing ? Self.minScrubbingUpdateInterval : Self.minUpdateInterval
    }

    private func handleSelectedDateChanged() {
        discardPendingTimeSliderDate()
        let timeZone = selectedTimeZone
        let currentObservationDate = StarMapDateLogic.observationDate(
            for: displayDate,
            timeZone: timeZone,
            nightStartMinutes: nightStartMinutes
        )
        guard !ObservationTimeZone.isDate(
            currentObservationDate,
            inSameDayAs: appController.selectedDate,
            timeZone: timeZone
        ) else {
            return
        }
        syncDisplayDate(referenceDate: displayDate)
    }

    private func discardPendingTimeSliderDate() {
        timeSliderScheduler.discardPending()
    }

    private func resyncAfterSelectionChange() {
        discardPendingTimeSliderDate()
        // 同一タイムゾーン内の地点変更では表示日時が変わらず didSet 経由の再計算が走らないため、
        // 表示日時が変わらなかった場合もスライダー同期・天体位置の再計算（地形取得を含む）を明示的に行う。
        if !syncDisplayDate(referenceDate: displayDate) {
            syncTimeSliderWithDisplayDate()
            update()
        }
    }

    private func setDisplayDate(_ date: Date, mode: DisplayDateUpdateMode) {
        displayDateUpdateMode = mode
        displayDate = date
    }

    private func handleDisplayDateChange(from oldDate: Date, to newDate: Date) {
        let updateMode = displayDateUpdateMode
        displayDateUpdateMode = .standard

        let shouldSkipTimeSliderSync = updateMode.skipsTimeSliderSync

        if !shouldSkipTimeSliderSync {
            syncTimeSliderWithDisplayDate()
        }

        update()
    }

    /// 夜間範囲を現在の日付・場所で再計算
    private func updateNightRange(referenceDate: Date) {
        let context = observationContext
        let fallback = StarMapDateLogic.NightRange(
            startMinutes: nightStartMinutes,
            durationMinutes: nightDurationMinutes
        )
        let range = StarMapDateLogic.nightRange(
            for: context.selectedDate,
            location: context.location,
            timeZone: context.timeZone,
            referenceDate: referenceDate,
            fallback: fallback
        )
        // 変化したときだけ書き込む（同値の代入は Observation も通知しない）。
        if nightStartMinutes != range.startMinutes {
            nightStartMinutes = range.startMinutes
        }
        if nightDurationMinutes != range.durationMinutes {
            nightDurationMinutes = range.durationMinutes
        }

        let timelineKey = TimelineCacheKey(
            latitude: context.location.latitude,
            longitude: context.location.longitude,
            observationDate: context.selectedDate,
            timeZoneIdentifier: context.timeZone.identifier,
            nightStartMinutes: range.startMinutes,
            nightDurationMinutes: range.durationMinutes
        )
        // キャッシュ一致時の値は前回このプロパティへ代入済みのため、再代入（=再描画通知）しない。
        guard cachedObservationTimeline?.key != timelineKey else { return }
        let timeline = StarMapObservationTimeline.build(
            location: context.location,
            observationDate: context.selectedDate,
            timeZone: context.timeZone,
            nightStartMinutes: range.startMinutes,
            nightDurationMinutes: range.durationMinutes
        )
        cachedObservationTimeline = (key: timelineKey, value: timeline)
        observationConditionTimeline = timeline
    }

    /// 夜間スライダーのオフセットを、現在の観測日に属する実際の表示日時へ変換します。
    private func makeDisplayDate(forTimeSliderMinutes minutes: Double) -> Date? {
        let context = observationContext
        let realMinutes = StarMapDateLogic.nightOffsetToRealMinutes(
            minutes,
            nightStartMinutes: nightStartMinutes
        )
        return StarMapDateLogic.date(
            bySettingClockMinutes: realMinutes,
            onObservationDate: context.selectedDate,
            timeZone: context.timeZone,
            nightStartMinutes: nightStartMinutes
        )
    }

    private func resolvedPresentationDate(
        for selectedDate: Date,
        referenceDate: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> Date? {
        StarMapDateLogic.resolvedPresentationDate(
            for: selectedDate,
            referenceDate: referenceDate,
            location: location,
            timeZone: timeZone
        )
    }

    nonisolated static func terrainCacheKey(latitude: Double, longitude: Double) -> String {
        TerrainService.cacheKey(latitude: latitude, longitude: longitude)
    }

    /// 視点が動いている間、前回の配置を流用してよいアンカーの最大移動量（pt）。超えたら配置し直す。
    nonisolated static let labelPlacementReuseDistance: Double = 24
    /// フレーム間のアンカー移動がこれ未満なら、視点は止まっているとみなす（pt）。
    nonisolated static let labelPlacementSettleDistance: Double = 0.5
    /// 動いている間でも、前回の最適化からこの時間が経ったら配置し直す。
    nonisolated static let labelPlacementMaximumReuseAge: Duration = .milliseconds(500)

    /// 星座ラベルの配置を計算する。視点（候補・キャンバスサイズ・下部余白）が前回と同一ならキャッシュを返す。
    /// `isViewMoving` が true でアンカーが前フレームから動いている間は、最適化を毎フレーム走らせず、
    /// 前回の配置を各アンカーの移動量だけ平行移動して返す（移動量が `labelPlacementReuseDistance` を超えたら配置し直す）。
    /// 動きが止まれば通常どおり配置し直すため、静止後の配置は常に最適化の結果と一致する。
    func labelPlacements(
        candidates: [ConstellationLabelCandidate],
        canvasSize: CGSize,
        reservedBottomInset: Double,
        isViewMoving: Bool = false
    ) -> [ConstellationLabelPlacement] {
        let key = LabelPlacementCacheKey(
            candidates: candidates,
            canvasSize: canvasSize,
            reservedBottomInset: reservedBottomInset
        )
        let previousCandidates = lastLabelCandidates
        lastLabelCandidates = candidates
        if let cached = cachedLabelPlacements, cached.key == key {
            return cached.value
        }
        let now = ContinuousClock.now
        if isViewMoving,
           let lastLabelLayoutTime,
           now - lastLabelLayoutTime < Self.labelPlacementMaximumReuseAge,
           let previousCandidates,
           let cached = cachedLabelPlacements,
           Self.maximumAnchorDisplacement(from: previousCandidates, to: candidates)
            .map({ $0 >= Self.labelPlacementSettleDistance }) == true,
           let translated = Self.translatedLabelPlacements(cached.value, from: cached.key, to: key) {
            return translated
        }
        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: candidates,
            canvasSize: canvasSize,
            reservedBottomInset: reservedBottomInset
        )
        cachedLabelPlacements = (key: key, value: placements)
        lastLabelLayoutTime = now
        return placements
    }

    /// 同じ星座が同じ順で並ぶ候補どうしのアンカー移動量の最大値。並びが違えば nil。
    nonisolated private static func maximumAnchorDisplacement(
        from previous: [ConstellationLabelCandidate],
        to current: [ConstellationLabelCandidate]
    ) -> Double? {
        guard previous.count == current.count else { return nil }
        var maximum = 0.0
        for (old, new) in zip(previous, current) {
            guard old.name == new.name else { return nil }
            maximum = max(maximum, hypot(new.anchor.x - old.anchor.x, new.anchor.y - old.anchor.y))
        }
        return maximum
    }

    /// 前回の配置を各アンカーの移動量だけ平行移動する。候補の並び・キャンバス・余白が違うか、
    /// 移動量が大きすぎる場合は nil（配置し直す）。
    nonisolated private static func translatedLabelPlacements(
        _ placements: [ConstellationLabelPlacement],
        from cachedKey: LabelPlacementCacheKey,
        to key: LabelPlacementCacheKey
    ) -> [ConstellationLabelPlacement]? {
        guard cachedKey.canvasSize == key.canvasSize,
              cachedKey.reservedBottomInset == key.reservedBottomInset,
              let displacement = maximumAnchorDisplacement(from: cachedKey.candidates, to: key.candidates),
              displacement <= labelPlacementReuseDistance else {
            return nil
        }
        var anchorByName: [String: CGPoint] = [:]
        for candidate in key.candidates {
            anchorByName[candidate.name] = candidate.anchor
        }
        return placements.map { placement in
            let anchor = anchorByName[placement.name] ?? placement.anchor
            let dx = anchor.x - placement.anchor.x
            let dy = anchor.y - placement.anchor.y
            return ConstellationLabelPlacement(
                name: placement.name,
                anchor: anchor,
                origin: CGPoint(x: placement.origin.x + dx, y: placement.origin.y + dy),
                size: placement.size
            )
        }
    }

}

extension StarPosition: Identifiable {
    /// カタログ内の位置で一意に識別する（赤経・赤緯は重複しうる）
    public var id: Int { catalogIndex }
}
