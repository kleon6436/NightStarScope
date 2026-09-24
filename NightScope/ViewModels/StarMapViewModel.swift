import Foundation
import CoreLocation
import Combine
import SwiftUI

/// 星空マップの設定と現在値を配信する依存関係。
@MainActor
struct StarMapSettingsDependency {
    let currentSettings: () -> StarMapDisplaySettings
    /// メインスレッドで配信すること。購読側でも念のためメインで受け取る。
    let changes: AnyPublisher<StarMapDisplaySettings, Never>

    static let live = StarMapSettingsDependency(
        currentSettings: {
            StarMapDisplaySettings.load()
        },
        // UserDefaults の変更通知は書き込んだスレッドで届くため、MainActor に隔離された map の前でメインへ移す。
        changes: NotificationCenter.default.userDefaultsChangesOnMain()
            .map { _ in StarMapDisplaySettings.load() }
            .removeDuplicates()
            .eraseToAnyPublisher()
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

@MainActor
/// 星空マップの描画状態、観測日時、視点操作をまとめて管理する。
final class StarMapViewModel: ObservableObject {

    // MARK: - Celestial object positions

    @Published private(set) var starPositions: [StarPosition] = []
    @Published private(set) var sunAltitude: Double = 0
    @Published private(set) var moonAltitude: Double = 0
    @Published private(set) var moonAzimuth: Double = 0
    @Published private(set) var moonPhase: Double = 0      // 0=新月, 0.5=満月, 1=新月
    @Published private(set) var galacticCenterAltitude: Double = 0
    @Published private(set) var galacticCenterAzimuth: Double = 0
    @Published private(set) var constellationLines: [ConstellationLineAltAz] = []
    @Published private(set) var constellationLabels: [ConstellationLabelAltAz] = []
    @Published private(set) var planetPositions: [PlanetPosition] = []
    @Published private(set) var meteorShowerRadiants: [(shower: MeteorShower, altitude: Double, azimuth: Double)] = []
    @Published private(set) var terrainProfile: TerrainProfile? = nil
    @Published private(set) var terrainFetchState: StarMapTerrainFetchState = .idle
    @Published private(set) var showsConstellationLines: Bool = StarMapDisplaySettings.defaultValue.showsConstellationLines
    @Published private(set) var showsConstellationLabels: Bool = StarMapDisplaySettings.defaultValue.showsConstellationLabels
    @Published private(set) var showsPlanets: Bool = StarMapDisplaySettings.defaultValue.showsPlanets
    @Published private(set) var showsMeteorShowers: Bool = StarMapDisplaySettings.defaultValue.showsMeteorShowers
    @Published private(set) var showsMilkyWay: Bool = StarMapDisplaySettings.defaultValue.showsMilkyWay
    /// 天の川バンドのキャッシュ (lat/LST が変わったときのみ再計算)
    @Published private(set) var milkyWayBandPoints: [MilkyWayBandPoint] = []
    @Published private(set) var observationConditionTimeline: [StarMapObservationConditionSample] = []

    // MARK: - Observation datetime (independent of AppController.selectedDate)

    @Published var displayDate: Date = Date() {
        didSet {
            handleDisplayDateChange(from: oldValue, to: displayDate)
        }
    }

    @Published private(set) var timeSliderMinutes: Double = 0
    @Published private(set) var isTimeSliderScrubbing: Bool = false

    /// 夜間開始時刻 (分, 0-1439) — 日没 (太陽高度 0°) 基準
    @Published private(set) var nightStartMinutes: Double = 1080  // デフォルト 18:00
    /// 夜間の長さ (分)
    @Published private(set) var nightDurationMinutes: Double = 600 // デフォルト 10時間

    // MARK: - View direction (full-sky planisphere rotation or gyro center)

    /// 画面中心が向く方位角 (度, 0=北, 時計回り)。パノラマモードでは中央の方位
    @Published var viewAzimuth: Double = 0   // 初期値=北向き

    /// 画面中心の仰角 (度, 0=地平線, 90=天頂)。ジャイロモードで使用
    @Published var viewAltitude: Double = 45

    /// 画面のロール角 (度)。ジャイロモード時のみ投影へ反映する
    @Published var viewRoll: Double = 0

    /// ジャイロモードの有効/無効 (iPhone のみ true にする)
    @Published var isGyroMode: Bool = false

    /// 水平視野角 (度): 30°〜150°, デフォルト 60°
    @Published var fov: Double = StarMapLayout.defaultFOV

    /// 星空マップ描画領域の最新サイズ
    @Published private(set) var canvasSize: CGSize = .zero

    /// 星空マップシートが表示中か（サイドバーの視野オーバーレイ連動用）
    @Published var isStarMapOpen: Bool = false

    /// 現在の視野方向（サイドバーマップオーバーレイ用）
    var viewingDirection: ViewingDirection {
        ViewingDirection(azimuth: viewAzimuth, fov: fov, isActive: isStarMapOpen)
    }

    // MARK: - Dependencies

    private let appController: AppController
    private let settingsDependency: StarMapSettingsDependency
    private let terrainCoordinator: StarMapTerrainCoordinator
    /// スライダー編集中の日時コミット間隔: 20fps
    private let timeSliderScheduler = StarMapTimeSliderScheduler(commitInterval: 1.0 / 20)
    private let computationDependency: StarMapComputationDependency
    private var cancellables: Set<AnyCancellable> = []
    private var shouldApplyInitialPose = true
    private var hasPreparedInitialPresentation = false
    private var displayDateUpdateMode: DisplayDateUpdateMode = .standard
    private var starMapDisplaySettings: StarMapDisplaySettings
    private var starDisplayDensity: StarDisplayDensity
    /// 星座ラベル配置の最終計算結果キャッシュ（視点が変化していなければ再計算をスキップする）
    private var cachedLabelPlacements: (key: LabelPlacementCacheKey, value: [ConstellationLabelPlacement])?
    /// 夜間タイムラインの最終計算結果キャッシュ（入力が変化していなければ再計算をスキップする）
    private var cachedObservationTimeline: (key: TimelineCacheKey, value: [StarMapObservationConditionSample])?

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
    }

    // MARK: - Calculation

    /// 進行中の計算タスク (新しい update() 呼び出しでキャンセルする)
    private var updateTask: Task<Void, Never>?
    /// trailing-edge debounce 用タスク
    private var trailingTask: Task<Void, Never>?
    /// 前回の計算開始タイムスタンプ (全 update() 呼び出しで共通スロットルに使用)
    private var lastPositionUpdateTime: TimeInterval = 0
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
        appController.locationController.selectedLocationPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resyncAfterSelectionChange()
            }
            .store(in: &cancellables)

        appController.locationController.selectedTimeZonePublisher
            .dropFirst()
            .removeDuplicates { $0.identifier == $1.identifier }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resyncAfterSelectionChange()
            }
            .store(in: &cancellables)

        settingsDependency.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.applyStarMapDisplaySettings(settings)
            }
            .store(in: &cancellables)

        appController.$selectedDate
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSelectedDateChanged()
            }
            .store(in: &cancellables)
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
        starPositions = snapshot.starPositions
        sunAltitude = snapshot.sunAltitude
        moonAltitude = snapshot.moonAltitude
        moonAzimuth = snapshot.moonAzimuth
        moonPhase = snapshot.moonPhase
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
        MeteorShowerCatalog.active(
            on: displayDate,
            timeZone: selectedTimeZone
        )
    }

    /// 次の流星群とピークまでの日数
    var nextMeteorShower: (shower: MeteorShower, daysUntilPeak: Int)? {
        MeteorShowerCatalog.next(
            after: displayDate,
            timeZone: selectedTimeZone
        )
    }

    /// 現在の表示が属する観測日の開始時刻です。
    var observationDate: Date {
        ObservationTimeZone.startOfDay(
            for: appController.selectedDate,
            timeZone: selectedTimeZone
        )
    }

    /// 太陽が地平線下 (夜間) か
    var isNight: Bool { sunAltitude < 0 }

    /// 現在の観測日と時刻にリセット
    func resetToNow(referenceDate: Date = Date()) {
        appController.selectObservationDate(referenceDate, timeZone: selectedTimeZone)
        syncWithSelectedDate(referenceDate: referenceDate)
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
        syncWithSelectedDate(referenceDate: displayDate)
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

    /// 星空マップ描画領域の最新サイズを記録する。
    func updateCanvasSize(_ size: CGSize) {
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

    /// 北向きへ戻す。
    func resetToNorth() {
        viewAzimuth = 0
        viewAltitude = StarMapLayout.resetAltitude
        viewRoll = 0
    }

    /// 選択日へ現在の時刻を反映し、表示日時を変更した場合は true を返す。
    @discardableResult
    func syncWithSelectedDate(referenceDate: Date = Date()) -> Bool {
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
        syncWithSelectedDate(referenceDate: displayDate)
    }

    private func discardPendingTimeSliderDate() {
        timeSliderScheduler.discardPending()
    }

    private func resyncAfterSelectionChange() {
        discardPendingTimeSliderDate()
        syncWithSelectedDate(referenceDate: displayDate)
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
        nightStartMinutes = range.startMinutes
        nightDurationMinutes = range.durationMinutes

        let timelineKey = TimelineCacheKey(
            latitude: context.location.latitude,
            longitude: context.location.longitude,
            observationDate: context.selectedDate,
            timeZoneIdentifier: context.timeZone.identifier,
            nightStartMinutes: range.startMinutes,
            nightDurationMinutes: range.durationMinutes
        )
        if let cached = cachedObservationTimeline, cached.key == timelineKey {
            observationConditionTimeline = cached.value
        } else {
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

    /// 星座ラベルの配置を計算する。視点（候補・キャンバスサイズ・下部余白）が前回と同一ならキャッシュを返す。
    func labelPlacements(
        candidates: [ConstellationLabelCandidate],
        canvasSize: CGSize,
        reservedBottomInset: Double
    ) -> [ConstellationLabelPlacement] {
        let key = LabelPlacementCacheKey(
            candidates: candidates,
            canvasSize: canvasSize,
            reservedBottomInset: reservedBottomInset
        )
        if let cached = cachedLabelPlacements, cached.key == key {
            return cached.value
        }
        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: candidates,
            canvasSize: canvasSize,
            reservedBottomInset: reservedBottomInset
        )
        cachedLabelPlacements = (key: key, value: placements)
        return placements
    }

}

extension StarPosition: Identifiable {
    /// 赤経・赤緯の組み合わせで一意に識別する
    public var id: String { "\(star.ra)-\(star.dec)" }
}
