import Foundation
import Combine
import CoreLocation
import os
#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.nightscope", category: "AppController")

/// アプリ全体の観測状態と外部データ更新を統括するコントローラ。
@MainActor
final class AppController: ObservableObject {
    /// View 層へ公開する観測状態のスナップショット。
    struct ObservationState {
        var selectedDate = Date()
        var nightSummary: NightSummary?
        var upcomingNights: [NightSummary] = []
        var starGazingIndex: StarGazingIndex?
        var upcomingIndexes: [Date: StarGazingIndex] = [:]
        var isCalculating = false
        var isUpcomingLoading = false
    }

    /// 観測地変更時に再計算へ渡す入力条件。
    struct LocationRefreshRequest {
        let selectedDate: Date
        let coordinate: CLLocationCoordinate2D
        let timeZoneIdentifier: String
        /// 予報の先頭にする観測日（現在の観測日）。nil の場合は取得側が既定の日付を使う。
        var upcomingStartDate: Date? = nil
    }

    /// 観測地更新時に、どこまで画面状態へ反映するかを表す。
    enum LocationRefreshDisposition: Equatable {
        case discard
        case applyAll
        case applyLocationDataOnly
    }

    /// 観測地変更後にまとめて反映する計算結果と外部データ。
    struct LocationRefreshPayload {
        let nightSummary: NightSummary
        let upcomingNights: [NightSummary]
        let weatherResult: WeatherFetchResult
        let lightPollutionResult: LightPollutionService.FetchResult
        let starGazingIndex: StarGazingIndex
        let upcomingIndexes: [Date: StarGazingIndex]
    }

    /// 現在選択中の座標・タイムゾーンをひとまとめにした内部コンテキスト。
    private struct SelectedLocationContext {
        let coordinate: CLLocationCoordinate2D
        let timeZone: TimeZone

        func matches(coordinate: CLLocationCoordinate2D, timeZoneIdentifier: String) -> Bool {
            self.coordinate.isSameCoordinate(as: coordinate) && timeZone.identifier == timeZoneIdentifier
        }
    }

    // MARK: - Dependencies
    let locationController: LocationController
    let weatherService: any WeatherProviding
    let lightPollutionService: LightPollutionService

    // MARK: - Published State
    @Published var selectedDate: Date = Date() {
        didSet { publishObservationStateIfNeeded() }
    }
    var nightSummary: NightSummary? {
        didSet { publishObservationStateIfNeeded() }
    }
    var upcomingNights: [NightSummary] = [] {
        didSet { publishObservationStateIfNeeded() }
    }
    var starGazingIndex: StarGazingIndex? {
        didSet { publishObservationStateIfNeeded() }
    }
    var upcomingIndexes: [Date: StarGazingIndex] = [:] {
        didSet { publishObservationStateIfNeeded() }
    }
    var isCalculating = false {
        didSet { publishObservationStateIfNeeded() }
    }
    var isUpcomingLoading = false {
        didSet { publishObservationStateIfNeeded() }
    }
    @Published private(set) var observationState = ObservationState()

    // MARK: - Private State
    let favoriteStore: any FavoriteLocationStoring
    /// iCloud への自動追加と、iCloud からの取り込みを担う。ストアと同じ寿命で、メイン画面と設定画面の両方から参照する。
    let favoriteSyncReconciler: FavoriteSyncReconciler
    let calculationService: NightCalculating
    private let starGazingIndexBuilder: StarGazingIndexBuilder
    private let locationRefreshFetcher: LocationRefreshFetcher
    /// 「今日（今夜）」の判定と星空指数の評価に使う現在時刻。テストでは固定値を注入する。
    private let now: () -> Date
    private var calculationTask: Task<Void, Never>?
    private var upcomingTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var externalDataTask: Task<Void, Never>?
    /// 前面にある間、一定間隔で外部データを取り直すタスク
    private var foregroundRefreshTask: Task<Void, Never>?
    /// 定期更新の待機処理（テストで差し替える）
    private let foregroundRefreshSleep: (TimeInterval) async throws -> Void
    /// 最後に外部データを取り直した時刻と観測地。自動更新の間引きに使う。
    private var lastExternalRefresh: (date: Date, context: SelectedLocationContext)?
    private var cancellables: Set<AnyCancellable> = []
    private var dashboardCommandBridgeCancellable: AnyCancellable?
    private var dashboardSelectionDateHandler: ((Date) -> Void)?
    private var hasStarted = false
    private var lastObservedTimeZone: TimeZone
    private var lastObservedCoordinate: CLLocationCoordinate2D
    private var lastActiveReferenceDate: Date
    private var observationStateBatchDepth = 0
    /// 観測日判定に使う夜の境界のキャッシュ。画面描画から繰り返し呼ばれても日没・日の出の探索を繰り返さない。
    private var observationDayBoundariesCache: (
        coordinate: CLLocationCoordinate2D,
        timeZoneIdentifier: String,
        boundaries: StarMapDateLogic.ObservationDayBoundaries
    )?

    // MARK: - Startup Stage 0

    /// Stage 0 は同期・最小の初期化に限定し、サービスのインスタンスだけを生成する。
    /// ファイル I/O・解凍・デコード・天体計算は行わない。
    /// 重いデータは起動後にロードする。
    /// 重いデータのロードは各サービスが非同期に行う。
    /// 光害グリッドは BortleGridProvider、星カタログは StarCatalog.preloadedStars() が担当する。
    init(locationController: LocationController? = nil,
         weatherService: (any WeatherProviding)? = nil,
         lightPollutionService: LightPollutionService? = nil,
         calculationService: NightCalculating? = nil,
         favoriteDefaults: UserDefaults = .standard,
         kvStore: any UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default,
         notificationCenter: NotificationCenter = .default,
         now: @escaping () -> Date = Date.init,
         foregroundRefreshSleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        let initStart = ContinuousClock.now
        self.locationController = locationController ?? LocationController()
        self.weatherService = weatherService ?? WeatherKitService()
        self.starGazingIndexBuilder = StarGazingIndexBuilder(weatherService: self.weatherService)
        self.now = now
        self.foregroundRefreshSleep = foregroundRefreshSleep
        self.lightPollutionService = lightPollutionService ?? LightPollutionService()
        let favorites = FavoritesComposition.make(
            defaults: favoriteDefaults,
            kvStore: kvStore,
            center: notificationCenter
        )
        self.favoriteStore = favorites.store
        self.favoriteSyncReconciler = favorites.reconciler
        self.calculationService = calculationService ?? NightCalculationService()
        self.locationRefreshFetcher = LocationRefreshFetcher(
            calculationService: self.calculationService,
            weatherService: self.weatherService,
            lightPollutionService: self.lightPollutionService
        )
        self.lastObservedTimeZone = self.locationController.selectedTimeZone
        self.lastObservedCoordinate = self.locationController.selectedLocation
        // 起動直後の「今日」も観測日で選ぶ。深夜〜明け方の起動では進行中の前夜を選ぶ。
        // Stage 0 の例外として日没・日の出の探索（2 夜分）だけを行う。ファイル I/O は伴わない。
        let launchDate = now()
        let launchLocation = self.locationController.selectedLocation
        let launchTimeZone = self.locationController.selectedTimeZone
        let launchBoundaries = StarMapDateLogic.observationDayBoundaries(
            containing: launchDate,
            location: launchLocation,
            timeZone: launchTimeZone
        )
        self.selectedDate = launchBoundaries.observationDate(for: launchDate)
        self.lastActiveReferenceDate = launchDate
        // onStart や画面描画での観測日判定が同じ探索を繰り返さないよう、境界をキャッシュしておく
        self.observationDayBoundariesCache = (
            coordinate: launchLocation,
            timeZoneIdentifier: launchTimeZone.identifier,
            boundaries: launchBoundaries
        )
        publishObservationState()
        setupObservers()
        // Stage 1 相当。星図を開く前に星カタログを先読みしてデコードを済ませる。
        Task.detached(priority: .utility) {
            _ = await StarCatalog.preloadedStars()
        }
        let elapsedMs = Int((ContinuousClock.now - initStart) / .milliseconds(1))
        logger.notice("event=appControllerInit elapsedMs=\(elapsedMs, privacy: .public)")
    }

    func bindDashboardCommandBridge(
        _ bridge: DashboardCommandBridge,
        onSelectDate: ((Date) -> Void)? = nil
    ) {
        dashboardSelectionDateHandler = onSelectDate
        dashboardCommandBridgeCancellable = bridge.selectionPublisher.sink { [weak self] selection in
            self?.handleDashboardSelection(selection)
        }
    }

    deinit {
        calculationTask?.cancel()
        upcomingTask?.cancel()
        locationTask?.cancel()
        externalDataTask?.cancel()
    }

    // MARK: - Startup Stage 1

    /// Stage 1 の開始点。描画後に当夜・予報計算と外部データ取得を非同期で開始する。
    /// `referenceDate` を省略すると注入された現在時刻を使う。選択日は現在の観測日（深夜〜明け方は前日）にする。
    func onStart(referenceDate: Date? = nil, refreshExternalData: Bool = true) {
        guard !hasStarted else { return }
        hasStarted = true
        let referenceDate = referenceDate ?? now()
        lastActiveReferenceDate = referenceDate
        selectedDate = currentObservationDate(referenceDate: referenceDate)
        recalculate()
        recalculateUpcoming(referenceDate: referenceDate)
        if refreshExternalData {
            refreshExternalDataInBackground()
        }
    }

    /// Stage 1 の再開点。前景復帰時も計算と外部データ取得を非同期で開始する。
    /// 再計算や更新処理は UI をブロックしない。
    /// 「今日」を追っていた（選択日が前回の観測日だった）ときだけ、観測日が切り替わったら新しい観測日へ進める。
    /// 観測日は夜が明けるまで切り替わらないため、今夜を見ている途中で深夜 0 時を越えても選択日は変わらない。
    func handleSceneDidBecomeActive(referenceDate: Date? = nil, refreshExternalData: Bool = true) {
        let referenceDate = referenceDate ?? now()
        guard hasStarted else {
            onStart(referenceDate: referenceDate, refreshExternalData: refreshExternalData)
            return
        }

        let timeZone = selectedTimeZone
        let previousObservationDate = currentObservationDate(referenceDate: lastActiveReferenceDate)
        let activeObservationDate = currentObservationDate(referenceDate: referenceDate)
        let wasTrackingCurrentNight = ObservationTimeZone.isDate(
            selectedDate,
            inSameDayAs: previousObservationDate,
            timeZone: timeZone
        )
        let observationDateDidChange = !ObservationTimeZone.isDate(
            previousObservationDate,
            inSameDayAs: activeObservationDate,
            timeZone: timeZone
        )

        lastActiveReferenceDate = referenceDate

        if observationDateDidChange && wasTrackingCurrentNight {
            selectedDate = activeObservationDate
            recalculate()
        }

        // 30 分ごとの定期更新で毎回 9 夜分を計算し直さないよう、観測日・観測地が変わった場合か予報が空の場合だけ計算する。
        let context = selectedLocationContext
        let upcomingMatchesLocation = upcomingNights.first.map {
            context.matches(coordinate: $0.location, timeZoneIdentifier: $0.timeZoneIdentifier)
        } ?? false
        if observationDateDidChange || !upcomingMatchesLocation {
            recalculateUpcoming(referenceDate: referenceDate)
        }
        if refreshExternalData && shouldAutomaticallyRefreshExternalData() {
            refreshExternalDataInBackground()
        }
    }

    // MARK: - Foreground Refresh

    /// 自動更新（前景復帰・定期更新）で外部データを取り直す最短間隔。
    /// WeatherKit の呼び出しを抑えつつ、現在気温の表示上限（90 分）より前に入れ替える。
    static let automaticRefreshInterval: TimeInterval = 30 * 60

    /// 前面にある間、`automaticRefreshInterval` ごとに前景復帰と同じ更新を行う。
    /// ウィンドウを開いたままでは前景復帰が起きず、日付切り替えや天気の再取得が止まるため。
    func startForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        // sleep を先に取り出し、待機中に自身を保持しない
        let sleep = foregroundRefreshSleep
        foregroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(Self.automaticRefreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.handleSceneDidBecomeActive(referenceDate: self.now())
            }
        }
    }

    /// 前面から外れたら定期更新を止める。
    func stopForegroundRefresh() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    /// 同じ観測地を `automaticRefreshInterval` 以内に取り直していれば自動更新を見送る。
    /// 直前の天気取得が失敗していれば、回線復帰後の前景復帰ですぐ取り直せるよう間引かない。
    private func shouldAutomaticallyRefreshExternalData() -> Bool {
        guard weatherService.errorMessage == nil else { return true }
        guard let lastExternalRefresh,
              isSelectedLocationContext(lastExternalRefresh.context) else { return true }
        return now().timeIntervalSince(lastExternalRefresh.date) >= Self.automaticRefreshInterval
    }

    // MARK: - Startup Stage 2

    /// Stage 2 は遅延・オンデマンドで、星図の初回計算は表示時に行う。
    /// 地形データは TerrainService の初回使用時に読み込む。

    // MARK: - Public Methods

    /// 注入された時計での現在時刻。星空指数のモード補正など、ベース指数と同じ「今」で評価したい箇所が使う。
    func currentDate() -> Date {
        now()
    }

    /// 現在の観測日（夜の始まる日）の 0:00 を、選択中の観測地・タイムゾーンで返す。アプリ全体の「今日」の定義。
    /// 前日の日没〜当日の日の出の間（深夜〜明け方）は前日を返す。
    /// - Parameter referenceDate: 判定に使う時刻。nil なら注入された現在時刻。
    func currentObservationDate(referenceDate: Date? = nil) -> Date {
        observationDate(
            for: referenceDate ?? now(),
            coordinate: locationController.selectedLocation,
            timeZone: selectedTimeZone
        )
    }

    /// 指定した時刻・観測地での観測日を返す。暦日と観測地が同じ間は夜の境界を使い回す。
    private func observationDate(
        for referenceDate: Date,
        coordinate: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> Date {
        if let cache = observationDayBoundariesCache,
           cache.timeZoneIdentifier == timeZone.identifier,
           cache.coordinate.isSameCoordinate(as: coordinate),
           ObservationTimeZone.isDate(cache.boundaries.today, inSameDayAs: referenceDate, timeZone: timeZone) {
            return cache.boundaries.observationDate(for: referenceDate)
        }
        let boundaries = StarMapDateLogic.observationDayBoundaries(
            containing: referenceDate,
            location: coordinate,
            timeZone: timeZone
        )
        observationDayBoundariesCache = (
            coordinate: coordinate,
            timeZoneIdentifier: timeZone.identifier,
            boundaries: boundaries
        )
        return boundaries.observationDate(for: referenceDate)
    }

    /// 選択中の観測地に対応する天気予報を更新します。
    func refreshWeather() async {
        await refreshWeather(using: selectedLocationContext)
    }

    /// 選択中の観測地に対応する光害データを更新します。
    func refreshLightPollution() async {
        await refreshLightPollution(using: selectedLocationContext)
    }

    /// 選択中の観測地に対応する外部データを同一コンテキストで更新します。
    func refreshExternalData() async {
        await refreshExternalData(using: selectedLocationContext)
    }

    /// 選択日を更新し、必要な当夜再計算を開始します。
    func selectObservationDate(_ date: Date, timeZone: TimeZone? = nil) {
        let effectiveTimeZone = timeZone ?? selectedTimeZone
        let normalizedDate = ObservationTimeZone.startOfDay(for: date, timeZone: effectiveTimeZone)
        guard !ObservationTimeZone.isDate(
            selectedDate,
            inSameDayAs: normalizedDate,
            timeZone: effectiveTimeZone
        ) else {
            return
        }
        selectedDate = normalizedDate
        recalculate()
    }

    /// 外部データ更新を fire-and-forget で開始します。
    func refreshExternalDataInBackground() {
        externalDataTask?.cancel()
        let context = selectedLocationContext
        lastExternalRefresh = (now(), context)
        externalDataTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshExternalData(using: context)
        }
    }

    private func bringMainWindowToFront() {
        #if os(macOS)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }

    // MARK: - Calculation

    /// 選択中の観測日・観測地で当夜の集計を再計算します。
    func recalculate() {
        calculationTask?.cancel()
        performObservationStateBatchUpdate {
            isCalculating = true
            nightSummary = nil
            starGazingIndex = nil
        }
        let context = selectedLocationContext
        let date = selectedDate
        calculationTask = Task {
            let summary = await calculationService.calculateNightSummary(
                date: date,
                location: context.coordinate,
                timeZone: context.timeZone
            )
            // 取り消されたときは、取り消した側が isCalculating を引き継いでいる。
            guard !Task.isCancelled else { return }
            // 取り消されずに観測地だけ変わっていたら、結果を捨てて今の観測地で計算し直す。
            // このタスクが isCalculating を下ろす役なので、ここで止めると読み込み中のまま残る。
            guard isSelectedLocationContext(context) else {
                recalculate()
                return
            }
            performObservationStateBatchUpdate {
                nightSummary = summary
                isCalculating = false
                recomputeStarGazingIndex()
            }
        }
    }

    /// 選択中の観測地に対する今後の予報日数分の集計を再計算します。
    /// 予報の先頭は現在の観測日（深夜〜明け方は進行中の前夜）にし、「今日」を追う選択日と揃える。
    /// - Parameter referenceDate: 現在時刻として扱う時刻。nil なら注入された現在時刻。
    func recalculateUpcoming(referenceDate: Date? = nil) {
        upcomingTask?.cancel()
        isUpcomingLoading = true
        let context = selectedLocationContext
        let today = observationDate(
            for: referenceDate ?? now(),
            coordinate: context.coordinate,
            timeZone: context.timeZone
        )
        upcomingTask = Task {
            let upcoming = await calculationService.calculateUpcomingNights(
                from: today,
                location: context.coordinate,
                timeZone: context.timeZone,
                days: ForecastConfiguration.upcomingNightCount
            )
            guard !Task.isCancelled else { return }
            // 観測地の変更直後は、場所変更タスクがこのタスクを取り消すより先に完了することがある。
            // 結果は捨て、isUpcomingLoading を下ろす役ごと今の観測地の計算に引き継ぐ。
            guard isSelectedLocationContext(context) else {
                recalculateUpcoming(referenceDate: referenceDate)
                return
            }
            performObservationStateBatchUpdate {
                upcomingNights = upcoming
                recomputeUpcomingIndexes()
                isUpcomingLoading = false
            }
        }
    }

    /// 予報再計算の完了まで待機します。
    func recalculateUpcomingAndWait(referenceDate: Date? = nil) async {
        recalculateUpcoming(referenceDate: referenceDate)
        await upcomingTask?.value
    }

    /// 当夜の星空指数を最新の夜間サマリー・外部データから再構築します。
    func recomputeStarGazingIndex() {
        guard let summary = nightSummary else { return }
        starGazingIndex = makeStarGazingIndex(
            nightSummary: summary,
            weatherByDate: weatherService.weatherByDate,
            bortleClass: lightPollutionService.bortleClass
        )
    }

    /// 今後の夜ごとの星空指数一覧を最新の外部データから再構築します。
    func recomputeUpcomingIndexes() {
        let context = selectedLocationContext
        // 観測地の変更直後は、旧タイムゾーンで計算した夜が場所変更タスクで消されるまで残っている。
        // キーが前後の日にずれた指数を作らないよう、選択中のタイムゾーンの夜だけを使う。
        upcomingIndexes = makeUpcomingIndexes(
            upcomingNights: upcomingNights.filter { $0.timeZoneIdentifier == context.timeZone.identifier },
            weatherByDate: weatherService.weatherByDate,
            bortleClass: lightPollutionService.bortleClass,
            timeZone: context.timeZone
        )
    }

    // MARK: - Private
    private var selectedTimeZone: TimeZone {
        locationController.selectedTimeZone
    }

    private var selectedLocationContext: SelectedLocationContext {
        SelectedLocationContext(
            coordinate: locationController.selectedLocation,
            timeZone: locationController.selectedTimeZone
        )
    }

    private func isSelectedLocationContext(_ context: SelectedLocationContext) -> Bool {
        selectedLocationContext.matches(
            coordinate: context.coordinate,
            timeZoneIdentifier: context.timeZone.identifier
        )
    }

    /// 場所変更後の再取得に備えて、既存の観測結果と外部データ状態を初期化します。
    func prepareForLocationChange() {
        prepareForLocationChange(using: selectedLocationContext)
    }

    /// 場所変更後の再取得に備えて、既存の観測結果と外部データ状態を初期化します。
    private func prepareForLocationChange(using context: SelectedLocationContext) {
        externalDataTask?.cancel()
        externalDataTask = nil
        cancelActiveCalculationTasks()
        performObservationStateBatchUpdate {
            isCalculating = true
            isUpcomingLoading = true
            nightSummary = nil
            upcomingNights = []
            starGazingIndex = nil
            upcomingIndexes = [:]
        }
        weatherService.prepareForLocationChange(
            latitude: context.coordinate.latitude,
            longitude: context.coordinate.longitude,
            timeZone: context.timeZone
        )
        lightPollutionService.prepareForLocationChange()
    }

    private func refreshWeather(using context: SelectedLocationContext) async {
        await weatherService.fetchWeather(
            latitude: context.coordinate.latitude,
            longitude: context.coordinate.longitude,
            timeZone: context.timeZone
        )
    }

    private func refreshLightPollution(using context: SelectedLocationContext) async {
        await lightPollutionService.fetch(
            latitude: context.coordinate.latitude,
            longitude: context.coordinate.longitude
        )
    }

    private func refreshExternalData(using context: SelectedLocationContext) async {
        await refreshWeather(using: context)
        guard !Task.isCancelled,
              selectedLocationContext.matches(
                  coordinate: context.coordinate,
                  timeZoneIdentifier: context.timeZone.identifier
              ) else { return }
        await refreshLightPollution(using: context)
    }

    private func publishObservationStateIfNeeded() {
        guard observationStateBatchDepth == 0 else { return }
        publishObservationState()
    }

    private func publishObservationState() {
        observationState = ObservationState(appController: self)
    }

    private func performObservationStateBatchUpdate(_ updates: () -> Void) {
        observationStateBatchDepth += 1
        updates()
        observationStateBatchDepth -= 1
        guard observationStateBatchDepth == 0 else { return }
        publishObservationState()
    }

    private func recomputeAllIndexes() {
        performObservationStateBatchUpdate {
            recomputeStarGazingIndex()
            recomputeUpcomingIndexes()
        }
    }

    /// 観測地の変更に追従して、ローカル日付補正と関連データの一括再取得を行います。
    private func handleLocationChanged() async {
        let context = selectedLocationContext
        let timeZone = context.timeZone
        let request = prepareLocationRefreshRequest(context: context, timeZone: timeZone)
        let refreshResults = await locationRefreshFetcher.fetch(for: request, timeZone: timeZone)
        guard !Task.isCancelled else { return }
        let disposition = locationRefreshDisposition(for: request)
        guard disposition != .discard else {
            // 取り消されずに観測地だけ変わっていた場合は、新しい場所変更タスクが来ない。
            // 読み込み中の表示を残さないよう、今の観測地で取り直す。
            scheduleLocationChangeHandling()
            return
        }

        applyLocationRefresh(
            LocationRefreshPayload(
                nightSummary: refreshResults.nightSummary,
                upcomingNights: refreshResults.upcomingNights,
                weatherResult: refreshResults.weatherResult,
                lightPollutionResult: refreshResults.lightPollutionResult,
                starGazingIndex: makeStarGazingIndex(
                    nightSummary: refreshResults.nightSummary,
                    weatherByDate: refreshResults.weatherResult.weatherByDate,
                    bortleClass: refreshResults.lightPollutionResult.bortleClass
                ),
                upcomingIndexes: makeUpcomingIndexes(
                    upcomingNights: refreshResults.upcomingNights,
                    weatherByDate: refreshResults.weatherResult.weatherByDate,
                    bortleClass: refreshResults.lightPollutionResult.bortleClass,
                    timeZone: timeZone
                )
            ),
            disposition: disposition
        )
    }

    private func prepareLocationRefreshRequest(
        context: SelectedLocationContext,
        timeZone: TimeZone
    ) -> LocationRefreshRequest {
        let normalizedDate = selectedDateAfterLocationChange(
            from: lastObservedTimeZone,
            to: timeZone,
            newCoordinate: context.coordinate
        )
        lastObservedTimeZone = timeZone
        lastObservedCoordinate = context.coordinate
        performObservationStateBatchUpdate {
            selectedDate = ObservationTimeZone.startOfDay(for: normalizedDate, timeZone: timeZone)
            prepareForLocationChange(using: context)
        }
        return LocationRefreshRequest(
            selectedDate: selectedDate,
            coordinate: context.coordinate,
            timeZoneIdentifier: context.timeZone.identifier,
            upcomingStartDate: observationDate(
                for: now(),
                coordinate: context.coordinate,
                timeZone: context.timeZone
            )
        )
    }

    private func scheduleLocationChangeHandling() {
        locationTask?.cancel()
        locationTask = Task { [weak self] in
            guard let self else { return }
            await handleLocationChanged()
        }
    }

    private func setupObservers() {
        locationController.$locationUpdateID
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleLocationChangeHandling()
            }
            .store(in: &cancellables)

        locationController.selectedTimeZonePublisher
            .dropFirst()
            .removeDuplicates { $0.identifier == $1.identifier }
            .sink { [weak self] timeZone in
                // @Published は willSet で流すため、ここで locationController.selectedTimeZone を読むと
                // まだ旧タイムゾーンが返る。流れてきた新しい値を使う。
                self?.handleSelectedTimeZoneChanged(to: timeZone)
            }
            .store(in: &cancellables)

        let externalDataPublisher = Publishers.Merge(
            weatherService.weatherByDatePublisher
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            lightPollutionService.bortleClassPublisher
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher()
        )
        externalDataPublisher
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.recomputeAllIndexes()
            }
            .store(in: &cancellables)
    }

    func locationRefreshDisposition(for request: LocationRefreshRequest) -> LocationRefreshDisposition {
        let context = selectedLocationContext
        guard context.matches(coordinate: request.coordinate, timeZoneIdentifier: request.timeZoneIdentifier) else {
            return .discard
        }

        if !ObservationTimeZone.isDate(
            selectedDate,
            inSameDayAs: request.selectedDate,
            timeZone: context.timeZone
        ) {
            return .applyLocationDataOnly
        }

        return .applyAll
    }

    /// 観測地変更で取得した一括データを、現在の選択状態に応じて安全に反映します。
    func applyLocationRefresh(
        _ payload: LocationRefreshPayload,
        disposition: LocationRefreshDisposition
    ) {
        // 古い観測地のデータは何も反映しない。読み込み中フラグは取り直す側が下ろす。
        guard disposition != .discard else { return }
        // キャッシュから返した天気は取り直していないため、自動更新の間引きは元の取得時刻を基準にする。
        // 現在時刻で上書きすると、地点を行き来するだけで再取得が永久に見送られる。
        lastExternalRefresh = (payload.weatherResult.cachedAt ?? now(), selectedLocationContext)
        weatherService.applyFetchResult(payload.weatherResult)
        lightPollutionService.applyFetchResult(payload.lightPollutionResult)
        performObservationStateBatchUpdate {
            upcomingNights = payload.upcomingNights
            upcomingIndexes = payload.upcomingIndexes
            isUpcomingLoading = false
        }

        switch disposition {
        case .discard:
            return
        case .applyAll:
            performObservationStateBatchUpdate {
                nightSummary = payload.nightSummary
                starGazingIndex = payload.starGazingIndex
                isCalculating = false
            }
        case .applyLocationDataOnly:
            if hasCurrentNightSummaryForSelection() {
                performObservationStateBatchUpdate {
                    recomputeStarGazingIndex()
                    isCalculating = false
                }
            } else {
                isCalculating = false
                recalculateCurrentNightIfNeeded()
            }
        }
    }

    /// 観測地が変わったときの選択日を返す。
    /// 旧地点の「今日」（観測日）を追っていた場合は新地点の観測日へ合わせ直し、それ以外は暦日を保つ。
    /// 暦日のまま写すと、東京の朝にニューヨークへ移ると現地では翌日の夜が選ばれてしまう。
    private func selectedDateAfterLocationChange(
        from previousTimeZone: TimeZone,
        to newTimeZone: TimeZone,
        newCoordinate: CLLocationCoordinate2D
    ) -> Date {
        let referenceDate = now()
        let previousObservationDate = observationDate(
            for: referenceDate,
            coordinate: lastObservedCoordinate,
            timeZone: previousTimeZone
        )
        if ObservationTimeZone.isDate(selectedDate, inSameDayAs: previousObservationDate, timeZone: previousTimeZone) {
            return observationDate(for: referenceDate, coordinate: newCoordinate, timeZone: newTimeZone)
        }
        return ObservationTimeZone.preservingCalendarDay(selectedDate, from: previousTimeZone, to: newTimeZone)
    }

    private func handleSelectedTimeZoneChanged(to newTimeZone: TimeZone) {
        let previousTimeZone = lastObservedTimeZone
        lastObservedTimeZone = newTimeZone

        let normalizedDate = selectedDateAfterLocationChange(
            from: previousTimeZone,
            to: newTimeZone,
            newCoordinate: locationController.selectedLocation
        )
        guard normalizedDate != selectedDate else { return }
        selectedDate = normalizedDate
    }

    private func cancelActiveCalculationTasks() {
        calculationTask?.cancel()
        calculationTask = nil
        upcomingTask?.cancel()
        upcomingTask = nil
    }

    func makeStarGazingIndex(
        nightSummary: NightSummary,
        weatherByDate: [String: DayWeatherSummary],
        bortleClass: Double?
    ) -> StarGazingIndex {
        starGazingIndexBuilder.index(
            for: nightSummary,
            weatherByDate: weatherByDate,
            bortleClass: bortleClass,
            referenceDate: now()
        )
    }

    func makeUpcomingIndexes(
        upcomingNights: [NightSummary],
        weatherByDate: [String: DayWeatherSummary],
        bortleClass: Double?,
        timeZone: TimeZone
    ) -> [Date: StarGazingIndex] {
        var indexes: [Date: StarGazingIndex] = [:]
        // 辞書のキーは表示側が選択中のタイムゾーンで引くため、そのタイムゾーンの日付で作る。
        // 呼び出し側は同じタイムゾーンで計算した夜だけを渡す。違うとキーが前後の日にずれるので、その夜は指数を作らない。
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let referenceDate = now()
        for night in upcomingNights {
            guard night.timeZoneIdentifier == timeZone.identifier else {
                assertionFailure("予報の夜のタイムゾーン \(night.timeZoneIdentifier) がキーのタイムゾーン \(timeZone.identifier) と違う")
                continue
            }
            indexes[calendar.startOfDay(for: night.date)] = starGazingIndexBuilder.index(
                for: night,
                weatherByDate: weatherByDate,
                bortleClass: bortleClass,
                referenceDate: referenceDate
            )
        }
        return indexes
    }

    private func hasCurrentNightSummaryForSelection() -> Bool {
        guard let nightSummary else { return false }
        let context = selectedLocationContext
        return ObservationTimeZone.isDate(
            nightSummary.date,
            inSameDayAs: selectedDate,
            timeZone: context.timeZone
        )
            && context.matches(coordinate: nightSummary.location, timeZoneIdentifier: nightSummary.timeZoneIdentifier)
    }

    private func recalculateCurrentNightIfNeeded() {
        guard !isCalculating else { return }
        guard !hasCurrentNightSummaryForSelection() else { return }
        recalculate()
    }

    private func handleDashboardSelection(_ selection: DashboardSelection) {
        // お気に入りの名前とタイムゾーンは分かっているので、逆ジオコーディングを待たずに即時反映する。
        // タイムゾーンが先に確定することで、続く日付選択が観測地の暦日として解釈される。
        locationController.selectCoordinate(
            CLLocationCoordinate2D(
                latitude: selection.location.latitude,
                longitude: selection.location.longitude
            ),
            name: selection.location.name,
            timeZoneIdentifier: selection.location.timeZoneIdentifier
        )
        dashboardSelectionDateHandler?(selection.date)
        bringMainWindowToFront()
    }
}

private extension AppController.ObservationState {
    @MainActor
    init(appController: AppController) {
        self.init(
            selectedDate: appController.selectedDate,
            nightSummary: appController.nightSummary,
            upcomingNights: appController.upcomingNights,
            starGazingIndex: appController.starGazingIndex,
            upcomingIndexes: appController.upcomingIndexes,
            isCalculating: appController.isCalculating,
            isUpcomingLoading: appController.isUpcomingLoading
        )
    }
}
