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
    /// 星空指数の「今日」判定に使う現在時刻。テストでは固定値を注入する。
    private let now: () -> Date
    private var calculationTask: Task<Void, Never>?
    private var upcomingTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var externalDataTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var dashboardCommandBridgeCancellable: AnyCancellable?
    private var dashboardSelectionDateHandler: ((Date) -> Void)?
    private var isApplyingLocationRefresh = false
    private var hasStarted = false
    private var lastObservedTimeZone: TimeZone
    private var lastActiveReferenceDate: Date
    private var observationStateBatchDepth = 0

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
         now: @escaping () -> Date = Date.init) {
        let initStart = ContinuousClock.now
        self.locationController = locationController ?? LocationController()
        self.weatherService = weatherService ?? WeatherKitService()
        self.starGazingIndexBuilder = StarGazingIndexBuilder(weatherService: self.weatherService)
        self.now = now
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
        self.selectedDate = ObservationTimeZone.startOfDay(
            for: Date(),
            timeZone: self.locationController.selectedTimeZone
        )
        self.lastActiveReferenceDate = Date()
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
    func onStart(referenceDate: Date = Date(), refreshExternalData: Bool = true) {
        guard !hasStarted else { return }
        hasStarted = true
        lastActiveReferenceDate = referenceDate
        selectedDate = ObservationTimeZone.startOfDay(for: referenceDate, timeZone: selectedTimeZone)
        recalculate()
        recalculateUpcoming(referenceDate: referenceDate)
        if refreshExternalData {
            refreshExternalDataInBackground()
        }
    }

    /// Stage 1 の再開点。前景復帰時も計算と外部データ取得を非同期で開始する。
    /// 再計算や更新処理は UI をブロックしない。
    func handleSceneDidBecomeActive(referenceDate: Date = Date(), refreshExternalData: Bool = true) {
        guard hasStarted else {
            onStart(referenceDate: referenceDate, refreshExternalData: refreshExternalData)
            return
        }

        let timeZone = selectedTimeZone
        let previousActiveDay = ObservationTimeZone.startOfDay(
            for: lastActiveReferenceDate,
            timeZone: timeZone
        )
        let currentActiveDay = ObservationTimeZone.startOfDay(for: referenceDate, timeZone: timeZone)
        let wasTrackingToday = ObservationTimeZone.isDate(
            selectedDate,
            inSameDayAs: previousActiveDay,
            timeZone: timeZone
        )
        let dayDidChange = !ObservationTimeZone.isDate(
            previousActiveDay,
            inSameDayAs: currentActiveDay,
            timeZone: timeZone
        )

        lastActiveReferenceDate = referenceDate

        if dayDidChange && wasTrackingToday {
            selectedDate = currentActiveDay
            recalculate()
        }

        recalculateUpcoming(referenceDate: referenceDate)
        if refreshExternalData {
            refreshExternalDataInBackground()
        }
    }

    // MARK: - Startup Stage 2

    /// Stage 2 は遅延・オンデマンドで、星図の初回計算は表示時に行う。
    /// 地形データは TerrainService の初回使用時に読み込む。

    // MARK: - Public Methods

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
            guard !Task.isCancelled, isSelectedLocationContext(context) else { return }
            performObservationStateBatchUpdate {
                nightSummary = summary
                isCalculating = false
                recomputeStarGazingIndex()
            }
        }
    }

    /// 選択中の観測地に対する今後の予報日数分の集計を再計算します。
    func recalculateUpcoming(referenceDate: Date = Date()) {
        upcomingTask?.cancel()
        isUpcomingLoading = true
        let context = selectedLocationContext
        let today = ObservationTimeZone.startOfDay(for: referenceDate, timeZone: context.timeZone)
        upcomingTask = Task {
            let upcoming = await calculationService.calculateUpcomingNights(
                from: today,
                location: context.coordinate,
                timeZone: context.timeZone,
                days: ForecastConfiguration.upcomingNightCount
            )
            // 観測地の変更直後は、場所変更タスクがこのタスクを取り消すより先に完了することがある。
            guard !Task.isCancelled, isSelectedLocationContext(context) else { return }
            performObservationStateBatchUpdate {
                upcomingNights = upcoming
                recomputeUpcomingIndexes()
                isUpcomingLoading = false
            }
        }
    }

    /// 予報再計算の完了まで待機します。
    func recalculateUpcomingAndWait(referenceDate: Date = Date()) async {
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
        guard disposition != .discard else { return }

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
        let normalizedDate = ObservationTimeZone.preservingCalendarDay(
            selectedDate,
            from: lastObservedTimeZone,
            to: timeZone
        )
        lastObservedTimeZone = timeZone
        performObservationStateBatchUpdate {
            selectedDate = ObservationTimeZone.startOfDay(for: normalizedDate, timeZone: timeZone)
            prepareForLocationChange(using: context)
        }
        return LocationRefreshRequest(
            selectedDate: selectedDate,
            coordinate: context.coordinate,
            timeZoneIdentifier: context.timeZone.identifier
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
            .sink { [weak self] _ in
                self?.handleSelectedTimeZoneChanged()
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
                guard let self, !self.isApplyingLocationRefresh else { return }
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
        isApplyingLocationRefresh = true
        weatherService.applyFetchResult(payload.weatherResult)
        lightPollutionService.applyFetchResult(payload.lightPollutionResult)
        performObservationStateBatchUpdate {
            upcomingNights = payload.upcomingNights
            upcomingIndexes = payload.upcomingIndexes
            isUpcomingLoading = false
        }
        isApplyingLocationRefresh = false

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

    private func handleSelectedTimeZoneChanged() {
        let newTimeZone = selectedTimeZone
        let previousTimeZone = lastObservedTimeZone
        lastObservedTimeZone = newTimeZone

        let normalizedDate = ObservationTimeZone.preservingCalendarDay(
            selectedDate,
            from: previousTimeZone,
            to: newTimeZone
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
        // 呼び出し側は同じタイムゾーンで計算した夜だけを渡す。違うとキーが前後の日にずれる。
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let referenceDate = now()
        for night in upcomingNights {
            assert(night.timeZoneIdentifier == timeZone.identifier)
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
        locationController.selectCoordinate(
            CLLocationCoordinate2D(
                latitude: selection.location.latitude,
                longitude: selection.location.longitude
            )
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
