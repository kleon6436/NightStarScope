import Combine
import CoreLocation
import MapKit

/// 選択地点、検索、現在地取得、タイムゾーン解決をまとめて管理する。
@MainActor
final class LocationController: NSObject, ObservableObject, LocationProviding {
    /// タイムゾーンが確定済みか暫定かを区別する。
    private enum TimeZoneSelectionSource: Equatable {
        case confirmed
        case provisional
    }

    /// 地点確定時の入力をまとめた内部リクエスト。
    private struct SelectionRequest {
        let coordinate: CLLocationCoordinate2D
        let fallbackName: String?
        let preferredDetails: ResolvedLocationDetails
        let preferredTimeZoneIdentifierForResolution: String?
        let provisionalTimeZoneIdentifier: String?
        let incrementsCenterTrigger: Bool
        /// 逆ジオコーディングの結果で上書きしない地点名（お気に入り等で名前が確定している場合）。
        var preservedName: String? = nil
        /// 名前・タイムゾーンがすべて確定済みで、逆ジオコーディングが不要かどうか。
        var skipsDetailResolution = false
    }

    /// 現在地として採用できる位置の条件。
    private enum LocationFixPolicy {
        /// これより古いキャッシュ位置は採用しない（秒）。
        static let maximumAge: TimeInterval = 60
        /// これより水平精度が悪い位置は採用しない（メートル）。
        static let maximumHorizontalAccuracy: CLLocationAccuracy = 1_000
    }

    /// CLLocation から取り出した Sendable な位置情報。
    private struct LocationFix: Sendable {
        let coordinate: CLLocationCoordinate2D
        let timestamp: Date
        let horizontalAccuracy: CLLocationAccuracy

        init(_ location: CLLocation) {
            coordinate = location.coordinate
            timestamp = location.timestamp
            horizontalAccuracy = location.horizontalAccuracy
        }

        /// 精度が有効（負値でない）かどうか。
        var hasValidAccuracy: Bool {
            horizontalAccuracy >= 0
        }

        /// 鮮度と精度の両方が基準を満たすかどうか。
        func isAcceptable(now: Date) -> Bool {
            hasValidAccuracy
                && horizontalAccuracy <= LocationFixPolicy.maximumHorizontalAccuracy
                && now.timeIntervalSince(timestamp) <= LocationFixPolicy.maximumAge
        }
    }

    // MARK: - Published State

    private let storage: LocationStorage
    private let searchService: LocationSearchServicing
    private let locationNameResolver: LocationNameResolving
    private let locationRequestTimeout: Duration

    @Published var selectedLocation: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503) {
        didSet {
            storage.latitude = selectedLocation.latitude
            storage.longitude = selectedLocation.longitude
        }
    }
    /// 既定地点（東京）と整合するよう、未保存時は端末のタイムゾーンではなく Asia/Tokyo を使う。
    @Published private(set) var selectedTimeZoneIdentifier = "Asia/Tokyo" {
        didSet { persistSelectedTimeZone() }
    }
    /// 再計算が必要な場所変更が起きるたびに更新される ID（View 側での onChange 検知用）
    @Published private(set) var locationUpdateID: UUID = UUID()
    var selectedLocationPublisher: AnyPublisher<CLLocationCoordinate2D, Never> {
        $selectedLocation.eraseToAnyPublisher()
    }
    var locationNamePublisher: AnyPublisher<String, Never> {
        $locationName.eraseToAnyPublisher()
    }
    var searchStatePublisher: AnyPublisher<LocationSearchState, Never> {
        $searchState.eraseToAnyPublisher()
    }
    var isLocatingPublisher: AnyPublisher<Bool, Never> {
        $isLocating.eraseToAnyPublisher()
    }
    var locationErrorPublisher: AnyPublisher<LocationError?, Never> {
        $locationError.eraseToAnyPublisher()
    }
    var searchFocusTriggerPublisher: AnyPublisher<Int, Never> {
        $searchFocusTrigger.eraseToAnyPublisher()
    }
    var currentLocationCenterTriggerPublisher: AnyPublisher<Int, Never> {
        $currentLocationCenterTrigger.eraseToAnyPublisher()
    }
    var selectedTimeZonePublisher: AnyPublisher<TimeZone, Never> {
        $selectedTimeZoneIdentifier
            .map { TimeZone(identifier: $0) ?? .current }
            .eraseToAnyPublisher()
    }
    var selectedTimeZone: TimeZone {
        TimeZone(identifier: selectedTimeZoneIdentifier) ?? .current
    }

    @Published var locationName: String = L10n.tr("東京") {
        didSet { storage.name = locationName }
    }
    @Published var searchState: LocationSearchState = .idle
    @Published var isLocating = false
    @Published var locationError: LocationError?
    @Published var searchFocusTrigger = 0
    /// 検索・現在地取得で場所が確定するたびにインクリメント（マップセンタリングのトリガー）
    @Published var currentLocationCenterTrigger = 0

    var searchResults: [MKMapItem] {
        get { searchState.results }
        set {
            let query = effectiveSearchQuery
            if newValue.isEmpty {
                searchState = query.isEmpty ? .idle : .empty(query: query)
            } else {
                searchState = .results(query: query, items: newValue)
            }
        }
    }

    var isSearching: Bool {
        get { searchState.isSearching }
        set {
            guard newValue != searchState.isSearching else { return }
            if newValue {
                searchState = .loading(query: effectiveSearchQuery, previousResults: searchState.results)
            } else {
                let query = effectiveSearchQuery
                searchState = query.isEmpty ? .idle : .empty(query: query)
            }
        }
    }

    // MARK: - Error

    enum LocationError: LocalizedError, Equatable {
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .denied:
                #if os(iOS)
                return L10n.tr("位置情報のアクセスが拒否されています。設定アプリで NightScope の位置情報を許可してください。")
                #else
                return L10n.tr("位置情報のアクセスが拒否されています。システム設定 > プライバシーとセキュリティ > 位置情報サービスで許可してください。")
                #endif
            case .failed:
                return L10n.tr("現在地を取得できませんでした。しばらく待ってから再試行してください。")
            }
        }
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var locationTimeoutTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var locationNameTask: Task<Void, Never>?
    private var latestSearchQuery = ""
    private var shouldResumeLocationAfterAuthorization = false
    /// 基準を満たさなかったが、タイムアウト時に代わりに使える最新の位置。
    private var bestLocationFixCandidate: LocationFix?
    private var selectedTimeZoneSelectionSource: TimeZoneSelectionSource = .confirmed
    private static let searchFailureMessage = L10n.tr("場所を検索できませんでした。通信状況を確認して、もう一度お試しください。")

    // MARK: - Init

    /// 永続化・検索・名称解決の依存関係を注入する。
    init(
        storage: LocationStorage = UserDefaultsLocationStorage(),
        searchService: LocationSearchServicing = MKLocationSearchService(),
        locationNameResolver: LocationNameResolving = ReverseGeocodingLocationNameResolver(),
        locationRequestTimeout: Duration = .seconds(60)
    ) {
        self.storage = storage
        self.searchService = searchService
        self.locationNameResolver = locationNameResolver
        self.locationRequestTimeout = locationRequestTimeout
        super.init()
        restorePersistedLocation()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    deinit {
        locationTimeoutTask?.cancel()
        searchTask?.cancel()
        locationNameTask?.cancel()
    }

    private func restorePersistedLocation() {
        let storedCoordinate = storedCoordinateFromStorage()
        switch storedCoordinate {
        case .some(let coordinate):
            selectedLocation = coordinate
            if let name = storage.name {
                locationName = name
            }
            if let timeZoneIdentifier = storage.timeZoneIdentifier,
               TimeZone(identifier: timeZoneIdentifier) != nil,
               !ApproximateTimeZoneResolver.isProvisionalIdentifier(timeZoneIdentifier) {
                _ = applySelectedTimeZone(identifier: timeZoneIdentifier, source: .confirmed)
            } else if let exactIdentifier = ApproximateTimeZoneResolver.exactIdentifier(for: coordinate) {
                _ = applySelectedTimeZone(identifier: exactIdentifier, source: .confirmed)
            } else {
                _ = applySelectedTimeZone(
                    identifier: ApproximateTimeZoneResolver.approximateIdentifier(for: coordinate),
                    source: .provisional
                )
            }
            // 暫定タイムゾーンや名前未保存のまま残らないよう、選択時と同様に逆ジオコーディングで解決する。
            // 保存済みの名前はユーザーが選んだものなので上書きしない。
            if selectedTimeZoneSelectionSource == .provisional || storage.name == nil {
                resolveLocationDetails(
                    for: coordinate,
                    fallbackName: storage.name ?? L10n.tr("選択した地点"),
                    preferredTimeZoneIdentifier: selectedTimeZoneSelectionSource == .confirmed
                        ? selectedTimeZoneIdentifier
                        : nil,
                    preservedName: storage.name
                )
            }
        case .none:
            if storage.latitude != nil || storage.longitude != nil {
                clearPersistedLocation()
            }
        }
    }

    private func storedCoordinateFromStorage() -> CLLocationCoordinate2D? {
        guard let lat = storage.latitude, let lon = storage.longitude else {
            return nil
        }
        return GeoStateValidator.sanitizedCoordinate(
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
    }

    private func clearPersistedLocation() {
        storage.latitude = nil
        storage.longitude = nil
        storage.name = nil
        storage.timeZoneIdentifier = nil
    }

    // MARK: - Public API

    /// 現在地取得を開始します。未許可の場合は権限ダイアログを要求します。
    func requestCurrentLocation() {
        let status = locationManager.authorizationStatus
        guard status != .denied, status != .restricted else {
            shouldResumeLocationAfterAuthorization = false
            locationError = .denied
            return
        }
        isLocating = true
        locationError = nil
        bestLocationFixCandidate = nil
        // 既に許可済みなら即開始、未決定なら locationManagerDidChangeAuthorization で開始する
        if Self.isAuthorized(status) {
            shouldResumeLocationAfterAuthorization = false
            startLocationUpdatesWithTimeout()
        } else {
            shouldResumeLocationAfterAuthorization = true
            // .notDetermined: 権限ダイアログへの応答を待機中。
            // ダイアログ表示中にタイムアウトで .failed を出さないよう、タイムアウトは許可後に
            // startLocationUpdatesWithTimeout() で開始する（拒否時は handleAuthorizationStatusChange で停止）。
            // macOS も Info.plist は NSLocationWhenInUseUsageDescription のみのため WhenInUse を要求する。
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func prepareForSettingsRecovery() {
        shouldResumeLocationAfterAuthorization = true
        locationError = nil
    }

    func refreshAuthorizationState() {
        handleAuthorizationStatusChange(locationManager.authorizationStatus)
    }

    /// クエリを正規化して場所検索を開始します。
    func search(query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearSearch()
            return
        }

        let isSameAsLatestQuery = normalizedQuery == latestSearchQuery
        if isSameAsLatestQuery && (searchState.isSearching || searchState.phase == .results) {
            return
        }

        latestSearchQuery = normalizedQuery
        searchTask?.cancel()
        searchState = .loading(query: normalizedQuery, previousResults: searchState.results)

        searchTask = Task { [normalizedQuery] in
            // デバウンス: 150ms 以内に次の入力があればキャンセルされる
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            do {
                let mapItems = try await searchService.search(query: normalizedQuery)
                guard !Task.isCancelled else { return }
                guard latestSearchQuery == normalizedQuery else { return }
                searchState = mapItems.isEmpty
                    ? .empty(query: normalizedQuery)
                    : .results(query: normalizedQuery, items: mapItems)
            } catch {
                guard !Task.isCancelled else { return }
                guard latestSearchQuery == normalizedQuery else { return }
                searchState = .failure(
                    query: normalizedQuery,
                    errorMessage: Self.searchFailureMessage
                )
            }
        }
    }

    /// 検索状態を初期化し、進行中の検索を取り消します。
    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        latestSearchQuery = ""
        searchState = .idle
    }

    /// 検索候補から場所を確定する（マップをセンタリングする）
    func select(_ mapItem: MKMapItem) {
        let preferredDetails = MapItemLocationDetailsExtractor.details(from: mapItem)
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26, macOS 26, *) {
            coordinate = mapItem.location.coordinate
        } else {
            coordinate = mapItem.placemark.coordinate
        }
        applySelection(
            SelectionRequest(
                coordinate: coordinate,
                fallbackName: mapItem.name,
                preferredDetails: preferredDetails,
                preferredTimeZoneIdentifierForResolution: preferredDetails.timeZoneIdentifier,
                provisionalTimeZoneIdentifier: preferredDetails.timeZoneIdentifier == nil
                    ? ApproximateTimeZoneResolver.approximateIdentifier(for: coordinate)
                    : nil,
                incrementsCenterTrigger: true
            )
        )
    }

    /// マップタップなど座標から場所を選択する（センタリングしない）
    func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectCoordinate(coordinate, provisionalName: L10n.tr("選択した地点"))
    }

    /// 保存済みの名前・タイムゾーンを持つ地点（お気に入り等）を選択する（センタリングしない）。
    /// 名前が渡された場合は逆ジオコーディングで上書きせず、有効なタイムゾーンは確定値として扱う。
    /// 逆ジオコーディングは名前またはタイムゾーンが欠けている場合のみ行う。
    func selectCoordinate(_ coordinate: CLLocationCoordinate2D, name: String?, timeZoneIdentifier: String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suppliedName: String? = trimmedName.isEmpty ? nil : trimmedName
        let confirmedTimeZoneIdentifier = ApproximateTimeZoneResolver.exactIdentifier(
            for: coordinate,
            preferredIdentifier: timeZoneIdentifier
        )
        let displayName = suppliedName ?? L10n.tr("選択した地点")
        applySelection(
            SelectionRequest(
                coordinate: coordinate,
                fallbackName: displayName,
                preferredDetails: ResolvedLocationDetails(
                    name: displayName,
                    timeZoneIdentifier: confirmedTimeZoneIdentifier
                ),
                preferredTimeZoneIdentifierForResolution: confirmedTimeZoneIdentifier,
                provisionalTimeZoneIdentifier: confirmedTimeZoneIdentifier == nil
                    ? ApproximateTimeZoneResolver.approximateIdentifier(for: coordinate)
                    : nil,
                incrementsCenterTrigger: false,
                preservedName: suppliedName,
                skipsDetailResolution: suppliedName != nil && confirmedTimeZoneIdentifier != nil
            )
        )
    }

    private func selectCoordinate(_ coordinate: CLLocationCoordinate2D, provisionalName: String) {
        let exactTimeZoneIdentifier = exactTimeZoneIdentifier(for: coordinate)
        applySelection(
            SelectionRequest(
                coordinate: coordinate,
                fallbackName: provisionalName,
                preferredDetails: ResolvedLocationDetails(
                    name: provisionalName,
                    timeZoneIdentifier: exactTimeZoneIdentifier
                ),
                preferredTimeZoneIdentifierForResolution: exactTimeZoneIdentifier,
                provisionalTimeZoneIdentifier: exactTimeZoneIdentifier == nil
                    ? ApproximateTimeZoneResolver.approximateIdentifier(for: coordinate)
                    : nil,
                incrementsCenterTrigger: false
            )
        )
    }

    // MARK: - Private Helpers

    /// 場所確定時の共通フローです。即時反映と非同期の詳細解決をまとめて扱います。
    private func applySelection(_ request: SelectionRequest) {
        if isLocating { stopLocating() }
        clearSearch()
        let didChangeCoordinate = applyCoordinateSelection(request.coordinate)
        let didChangeTimeZone = applyResolvedLocationDetails(
            for: request.coordinate,
            details: request.preferredDetails,
            fallbackName: request.fallbackName,
            provisionalTimeZoneIdentifier: request.provisionalTimeZoneIdentifier
        )
        if didChangeCoordinate || didChangeTimeZone {
            commitLocationUpdate()
        }
        if request.incrementsCenterTrigger {
            currentLocationCenterTrigger += 1
        }
        guard !request.skipsDetailResolution else {
            // 前の選択の解決結果が後から届いて上書きしないよう取り消す。
            locationNameTask?.cancel()
            locationNameTask = nil
            return
        }
        resolveLocationDetails(
            for: request.coordinate,
            fallbackName: request.fallbackName,
            preferredTimeZoneIdentifier: request.preferredTimeZoneIdentifierForResolution,
            preservedName: request.preservedName
        )
    }

    private func stopLocating(clearPendingAuthorizationRequest: Bool = true) {
        cancelLocationTimeout()
        isLocating = false
        bestLocationFixCandidate = nil
        locationManager.stopUpdatingLocation()
        if clearPendingAuthorizationRequest {
            shouldResumeLocationAfterAuthorization = false
        }
    }

    private func handleAuthorizationStatusChange(_ status: CLAuthorizationStatus) {
        if Self.isAuthorized(status) {
            locationError = nil
            guard isLocating || shouldResumeLocationAfterAuthorization else { return }
            shouldResumeLocationAfterAuthorization = false
            isLocating = true
            startLocationUpdatesWithTimeout()
            return
        }

        guard status == .denied || status == .restricted else { return }
        // 起動時の初回コールバックやシーン復帰時の再確認では位置を要求していないため、
        // 取得中・許可待ちのときだけ拒否エラーを出す（取得は常に止める）。
        let hadPendingRequest = isLocating || shouldResumeLocationAfterAuthorization
        stopLocating()
        if hadPendingRequest {
            locationError = .denied
        }
    }

    /// タイムアウトタスクのみを開始する（位置情報更新は開始しない）。
    /// 権限未決定で応答待ちの場合や startLocationUpdatesWithTimeout() の内部から使用する。
    func startLocatingTimeout() {
        cancelLocationTimeout()
        let timeout = locationRequestTimeout
        locationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            if self.isLocating {
                // 基準を満たす位置が届かなくても、受け取った位置があればそれを使う。
                if let candidate = self.bestLocationFixCandidate {
                    self.acceptLocationFix(candidate)
                    return
                }
                let isAwaitingAuthorizationDecision =
                    self.shouldResumeLocationAfterAuthorization
                    && self.locationManager.authorizationStatus == .notDetermined
                self.stopLocating(clearPendingAuthorizationRequest: !isAwaitingAuthorizationDecision)
                self.locationError = .failed
            }
        }
    }

    private func startLocationUpdatesWithTimeout() {
        startLocatingTimeout()
        locationManager.startUpdatingLocation()
    }

    private func cancelLocationTimeout() {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
    }

    private func commitLocationUpdate() {
        locationUpdateID = UUID()
    }

    @discardableResult
    private func applyCoordinateSelection(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard !selectedLocation.isSameCoordinate(as: coordinate) else {
            return false
        }
        selectedLocation = coordinate
        return true
    }

    @discardableResult
    private func applyResolvedLocationDetails(
        for coordinate: CLLocationCoordinate2D,
        details: ResolvedLocationDetails,
        fallbackName: String?,
        provisionalTimeZoneIdentifier: String? = nil
    ) -> Bool {
        locationName = resolvedLocationName(details.name, fallbackName: fallbackName)
        if let timeZoneIdentifier = resolvedTimeZoneIdentifier(
            for: coordinate,
            preferredIdentifier: details.timeZoneIdentifier
        ) {
            return applySelectedTimeZone(identifier: timeZoneIdentifier, source: .confirmed)
        }
        if let provisionalTimeZoneIdentifier {
            return applySelectedTimeZone(identifier: provisionalTimeZoneIdentifier, source: .provisional)
        }
        return false
    }

    private func resolveLocationDetails(
        for coordinate: CLLocationCoordinate2D,
        fallbackName: String?,
        preferredTimeZoneIdentifier: String?,
        preservedName: String? = nil
    ) {
        locationNameTask?.cancel()
        locationNameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let details = await self.locationNameResolver.resolveDetails(for: coordinate)
            guard !Task.isCancelled else { return }
            guard self.selectedLocation.isSameCoordinate(as: coordinate) else { return }
            let didChangeTimeZone = self.applyResolvedLocationDetails(
                for: coordinate,
                details: ResolvedLocationDetails(
                    name: preservedName ?? details.name,
                    timeZoneIdentifier: details.timeZoneIdentifier ?? preferredTimeZoneIdentifier
                ),
                fallbackName: fallbackName
            )
            if didChangeTimeZone {
                self.commitLocationUpdate()
            }
        }
    }

    private func resolvedLocationName(_ preferredName: String, fallbackName: String?) -> String {
        let trimmedPreferredName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFallbackName = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentLocationName = L10n.tr("現在地")

        if (trimmedPreferredName == "現在地" || trimmedPreferredName == currentLocationName),
           !trimmedFallbackName.isEmpty {
            return trimmedFallbackName
        }

        if !trimmedPreferredName.isEmpty {
            return trimmedPreferredName
        }

        return trimmedFallbackName.isEmpty ? L10n.tr("選択した地点") : trimmedFallbackName
    }

    private func resolvedTimeZoneIdentifier(
        for coordinate: CLLocationCoordinate2D,
        preferredIdentifier: String?
    ) -> String? {
        ApproximateTimeZoneResolver.exactIdentifier(
            for: coordinate,
            preferredIdentifier: preferredIdentifier
        )
    }

    private func exactTimeZoneIdentifier(for coordinate: CLLocationCoordinate2D) -> String? {
        ApproximateTimeZoneResolver.exactIdentifier(for: coordinate)
    }

    private func applySelectedTimeZone(identifier: String, source: TimeZoneSelectionSource) -> Bool {
        let didChangeIdentifier = selectedTimeZoneIdentifier != identifier
        let didChangeSource = selectedTimeZoneSelectionSource != source
        selectedTimeZoneSelectionSource = source

        if didChangeIdentifier {
            selectedTimeZoneIdentifier = identifier
        } else if didChangeSource {
            persistSelectedTimeZone()
        }

        return didChangeIdentifier || didChangeSource
    }

    private func persistSelectedTimeZone() {
        switch selectedTimeZoneSelectionSource {
        case .confirmed:
            storage.timeZoneIdentifier = selectedTimeZoneIdentifier
        case .provisional:
            storage.timeZoneIdentifier = nil
        }
    }

    private var effectiveSearchQuery: String {
        if !latestSearchQuery.isEmpty {
            return latestSearchQuery
        }
        return searchState.query
    }

    /// macOS では .authorizedWhenInUse が使えず、許可時は常に .authorizedAlways になる。
    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        status == .authorizedAlways
        #else
        status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    /// 受け取った位置を評価し、基準を満たせば現在地として確定、満たさなければ候補として保持する。
    private func handleReceivedLocationFixes(_ fixes: [LocationFix]) {
        guard isLocating else {
            locationManager.stopUpdatingLocation()
            return
        }
        let now = Date()
        if let acceptable = fixes.last(where: { $0.isAcceptable(now: now) }) {
            acceptLocationFix(acceptable)
            return
        }
        // 古い・精度不足の位置は待機を続けつつ、タイムアウト時の代替として最新の有効な位置を残す。
        if let candidate = fixes.last(where: \.hasValidAccuracy),
           bestLocationFixCandidate.map({ candidate.timestamp >= $0.timestamp }) ?? true {
            bestLocationFixCandidate = candidate
        }
    }

    private func acceptLocationFix(_ fix: LocationFix) {
        bestLocationFixCandidate = nil
        selectCoordinate(fix.coordinate, provisionalName: L10n.tr("現在地"))
        currentLocationCenterTrigger += 1
    }

}

// MARK: - CLLocationManagerDelegate

extension LocationController: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(LocationFix.init)
        guard !fixes.isEmpty else { return }
        // 停止は採用時（stopLocating）に行う。古い・精度不足の位置では更新を続ける。
        Task { @MainActor in
            self.handleReceivedLocationFixes(fixes)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .denied else {
            // kCLErrorLocationUnknown など一時的なエラーは無視して待ち続ける
            // (startUpdatingLocation は内部で再試行するため)
            return
        }
        Task { @MainActor in
            // 権限エラーは致命的なので停止してエラー表示
            self.stopLocating()
            self.locationError = .denied
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.handleAuthorizationStatusChange(status)
        }
    }
}
