import SwiftUI
import MapKit

/// 位置入力のソースを表す。
enum LocationInputMode: String, CaseIterable, Identifiable {
    case map
    case lightPollutionMap

    var id: String { rawValue }
}

@MainActor
/// サイドバーの検索・お気に入り・位置情報を同期する ViewModel。
@Observable
final class SidebarViewModel {
    /// 検索結果確定時に入力欄へ名前を残すかどうか。
    enum SearchTextSelectionBehavior {
        case fillSelectionName
        case clear
    }

    /// サイドバー内での検索結果の表示状態。
    enum SearchPresentation {
        case hidden
        case loading([MKMapItem])
        case results([MKMapItem])
        case empty(String)
        case error(query: String, message: String)
    }

    private enum PendingLocationUpdateBehavior {
        case preserveCommittedSelection(String)
        case clearSearch
    }

    private enum ViewportUpdateThresholds {
        static let coordinateEpsilon = 0.00005
        static let spanEpsilon = 0.00005
    }

    var viewport = ViewportBox()
    var searchText = ""
    private(set) var isShowingCommittedSelection = false
    // 地点・光害サービス（@Observable）の状態は転送し、読み出し時に Observation が追跡する。
    var searchState: LocationSearchState { locationController.searchState }
    var isLocating: Bool { locationController.isLocating }
    var locationError: LocationController.LocationError? { locationController.locationError }
    var selectedCoordinate: CLLocationCoordinate2D { locationController.selectedLocation }
    var selectedLocationName: String { locationController.locationName }
    var searchFocusTrigger: Int { locationController.searchFocusTrigger }
    var currentLocationCenterTrigger: Int { locationController.currentLocationCenterTrigger }
    var lightPollutionBortleClass: Double? { lightPollutionService.bortleClass }
    var isLightPollutionLoading: Bool { lightPollutionService.isLoading }
    var hasLightPollutionFetchFailed: Bool { lightPollutionService.fetchFailed }
    var isLightPollutionOutOfCoverage: Bool { lightPollutionService.isOutOfCoverage }
    var selectedTimeZone: TimeZone { locationController.selectedTimeZone }
    /// お気に入りストア（@Observable）へ転送する。ストアは他画面（複数地点ダッシュボード等）からも更新される。
    var favorites: [FavoriteLocation] { favoriteStore.loadAll() }
    /// お気に入り地点ごとの今夜の星空指数。未取得の地点はキーを持たない。
    /// FavoriteTonightScoreProvider（@Observable）へ転送し、読み出し時に Observation が追跡する。
    var favoriteTonightScores: [UUID: FavoriteTonightScore] {
        tonightScoreProvider?.scoresByFavoriteID ?? [:]
    }
    var isRefreshingFavoriteScores: Bool {
        tonightScoreProvider?.isRefreshing ?? false
    }

    @ObservationIgnored let locationController: any LocationProviding
    @ObservationIgnored let lightPollutionService: any LightPollutionProviding
    /// 未注入（テスト等）の場合は指数表示を行わない。
    @ObservationIgnored let tonightScoreProvider: FavoriteTonightScoreProvider?
    @ObservationIgnored private let favoriteStore: any FavoriteLocationStoring
    @ObservationIgnored private var pendingLocationUpdateBehavior: PendingLocationUpdateBehavior?
    @ObservationIgnored private var lightPollutionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var selectedLocationObservationTask: Task<Void, Never>?

    var isSearching: Bool {
        searchState.isSearching
    }

    var searchResults: [MKMapItem] {
        searchState.results
    }

    var searchPresentation: SearchPresentation {
        guard !isShowingCommittedSelection else { return .hidden }

        switch searchState.phase {
        case .idle:
            return .hidden
        case .loading:
            return .loading(searchState.results)
        case .results:
            return searchState.results.isEmpty ? .hidden : .results(searchState.results)
        case .empty:
            return .empty(searchState.query)
        case .failure:
            return .error(
                query: searchState.query,
                message: searchState.errorMessage ?? L10n.tr("場所を検索できませんでした")
            )
        }
    }

    /// 各サービスの状態を購読し、サイドバーの表示状態へ反映する。
    init(
        locationController: some LocationProviding,
        lightPollutionService: some LightPollutionProviding,
        favoriteStore: some FavoriteLocationStoring = FavoriteLocationStore(),
        tonightScoreProvider: FavoriteTonightScoreProvider? = nil
    ) {
        self.locationController = locationController
        self.lightPollutionService = lightPollutionService
        self.favoriteStore = favoriteStore
        self.tonightScoreProvider = tonightScoreProvider

        // 地点が確定したら、直前の意図に従って検索欄を戻す。
        // Observations は購読開始時の値も流すため、開始時点の座標と比べて変わったときだけ扱う（旧 dropFirst）。
        // LocationController は座標が変わったときだけ selectedLocation を書き換えるため、比較で取りこぼす変更はない。
        let initialCoordinate = locationController.selectedLocation
        let coordinateChanges = Observations { locationController.selectedLocation }
        selectedLocationObservationTask = Task { [weak self] in
            var lastCoordinate = initialCoordinate
            for await coordinate in coordinateChanges {
                guard let self else { return }
                guard coordinate.latitude != lastCoordinate.latitude
                    || coordinate.longitude != lastCoordinate.longitude else { continue }
                lastCoordinate = coordinate
                self.applyPendingLocationUpdateBehavior()
            }
        }
    }

    deinit {
        selectedLocationObservationTask?.cancel()
    }

    func handleLocationSectionAppear(selectedCoordinate: CLLocationCoordinate2D) {
        viewport.center = selectedCoordinate
    }

    func clearLocationError() {
        locationController.locationError = nil
    }

    func updateSearchText(_ searchText: String) {
        guard self.searchText != searchText else { return }
        self.searchText = searchText
        isShowingCommittedSelection = false
        locationController.search(query: searchText)
    }

    func selectSearchResult(_ item: MKMapItem, searchTextBehavior: SearchTextSelectionBehavior) {
        let locationName = item.name ?? ""
        pendingLocationUpdateBehavior = pendingBehavior(
            for: searchTextBehavior,
            selectedLocationName: locationName
        )
        applySearchSelectionPresentation(
            for: searchTextBehavior,
            selectedLocationName: locationName
        )
        locationController.select(item)
    }

    func clearSearch() {
        pendingLocationUpdateBehavior = nil
        resetSearchPresentation()
        locationController.clearSearch()
    }

    func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        pendingLocationUpdateBehavior = .clearSearch
        resetSearchPresentation()
        locationController.selectCoordinate(coordinate)
    }

    func requestCurrentLocation() {
        pendingLocationUpdateBehavior = .clearSearch
        // 同一座標が返ると selectedLocation が変化せず applyPendingLocationUpdateBehavior()
        // が呼ばれない経路があるため、ここで即時リセットする。
        // pendingLocationUpdateBehavior は座標変更経路でも再度 .clearSearch を適用するため保持。
        resetSearchPresentation()
        locationController.requestCurrentLocation()
    }

    func prepareForLocationSettingsRecovery() {
        locationController.prepareForSettingsRecovery()
    }

    func refreshLocationAuthorizationState() {
        locationController.refreshAuthorizationState()
    }

    func updateViewportIfNeeded(center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        let currentCenter = viewport.center
        let currentSpan = viewport.span

        let shouldUpdateCenter =
            abs(currentCenter.latitude - center.latitude) > ViewportUpdateThresholds.coordinateEpsilon
            || abs(currentCenter.longitude - center.longitude) > ViewportUpdateThresholds.coordinateEpsilon

        let shouldUpdateSpan =
            abs(currentSpan.latitudeDelta - span.latitudeDelta) > ViewportUpdateThresholds.spanEpsilon
            || abs(currentSpan.longitudeDelta - span.longitudeDelta) > ViewportUpdateThresholds.spanEpsilon

        if shouldUpdateCenter {
            viewport.center = center
        }
        if shouldUpdateSpan {
            viewport.span = span
        }
    }

    func retrySearch() {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return }
        isShowingCommittedSelection = false
        locationController.search(query: normalizedQuery)
    }

    func retryLightPollution() {
        lightPollutionRetryTask?.cancel()
        lightPollutionRetryTask = Task {
            await lightPollutionService.fetch(
                latitude: selectedCoordinate.latitude,
                longitude: selectedCoordinate.longitude
            )
        }
    }

    private func applyPendingLocationUpdateBehavior() {
        // 選択確定後に検索欄をどう戻すかを、直前の意図に従って一度だけ反映する。
        let behavior = pendingLocationUpdateBehavior ?? .clearSearch
        pendingLocationUpdateBehavior = nil

        switch behavior {
        case .preserveCommittedSelection(let selectedLocationName):
            searchText = selectedLocationName
            isShowingCommittedSelection = true
        case .clearSearch:
            resetSearchPresentation()
        }
    }

    private func pendingBehavior(
        for searchTextBehavior: SearchTextSelectionBehavior,
        selectedLocationName: String
    ) -> PendingLocationUpdateBehavior {
        switch searchTextBehavior {
        case .fillSelectionName:
            return .preserveCommittedSelection(selectedLocationName)
        case .clear:
            return .clearSearch
        }
    }

    private func applySearchSelectionPresentation(
        for searchTextBehavior: SearchTextSelectionBehavior,
        selectedLocationName: String
    ) {
        switch searchTextBehavior {
        case .fillSelectionName:
            searchText = selectedLocationName
            isShowingCommittedSelection = true
        case .clear:
            resetSearchPresentation()
        }
    }

    private func resetSearchPresentation() {
        searchText = ""
        isShowingCommittedSelection = false
    }

    // MARK: - Favorites

    var isCurrentLocationFavorited: Bool {
        let coord = locationController.selectedLocation
        return favorites.contains { $0.isNear(latitude: coord.latitude, longitude: coord.longitude) }
    }

    func addCurrentLocationToFavorites() {
        guard !isCurrentLocationFavorited else { return }
        let favorite = FavoriteLocation(
            name: locationController.locationName,
            latitude: locationController.selectedLocation.latitude,
            longitude: locationController.selectedLocation.longitude,
            timeZoneIdentifier: locationController.selectedTimeZone.identifier
        )
        favoriteStore.save(favorites + [favorite])
    }

    func toggleCurrentLocationFavorite() {
        if isCurrentLocationFavorited {
            removeCurrentLocationFromFavorites()
        } else {
            addCurrentLocationToFavorites()
        }
    }

    private func removeCurrentLocationFromFavorites() {
        let coord = locationController.selectedLocation
        favoriteStore.save(favorites.filter { !$0.isNear(latitude: coord.latitude, longitude: coord.longitude) })
    }

    func removeFavorite(_ favorite: FavoriteLocation) {
        favoriteStore.save(favorites.filter { $0.id != favorite.id })
    }

    func removeFavorites(at offsets: IndexSet) {
        var updated = favorites
        updated.remove(atOffsets: offsets)
        favoriteStore.save(updated)
    }

    /// 表示中のお気に入りについて、キャッシュが古いものだけ今夜の指数を再計算する。
    func refreshFavoriteScoresIfNeeded(force: Bool = false) async {
        guard let tonightScoreProvider else { return }
        await tonightScoreProvider.refreshIfNeeded(favorites: favorites, force: force)
    }

    func selectFavorite(_ favorite: FavoriteLocation) {
        pendingLocationUpdateBehavior = .clearSearch
        resetSearchPresentation()
        // 保存済みの名前とタイムゾーンをそのまま使う（暫定名・推定タイムゾーンで上書きしない）。
        locationController.selectCoordinate(
            CLLocationCoordinate2D(latitude: favorite.latitude, longitude: favorite.longitude),
            name: favorite.name,
            timeZoneIdentifier: favorite.timeZoneIdentifier
        )
        locationController.currentLocationCenterTrigger += 1
    }

    // MARK: - Sidebar Layout

    /// 検索結果・お気に入りの表示状態に応じたサイドバー内の追加リスト数
    var extraListCount: Int {
        let hasResults: Bool = {
            if case .results = searchPresentation { return true }
            return false
        }()
        return (hasResults ? 1 : 0) + (favorites.isEmpty ? 0 : 1)
    }

    var dynamicMapMinHeight: CGFloat {
        switch extraListCount {
        case 2: return 120
        case 1: return 150
        default: return Layout.mapMinHeight
        }
    }

    var dynamicMapMaxHeight: CGFloat {
        return .infinity
    }

    var calendarCellHeight: CGFloat {
        switch extraListCount {
        case 2: return 18
        case 1: return 20
        default: return 24
        }
    }
}

enum SidebarSearchInteraction {
    static let noSelectionIndex = -1
    static let maxVisibleResults = 5

    static func highlightedTarget(in results: [MKMapItem], highlightedIndex: Int) -> MKMapItem? {
        if results.indices.contains(highlightedIndex) {
            return results[highlightedIndex]
        }
        return results.first
    }

    static func nextHighlightedIndex(current: Int, totalResults: Int) -> Int {
        let count = min(totalResults, maxVisibleResults)
        guard count > 0 else { return current }
        return min(current + 1, count - 1)
    }

    static func previousHighlightedIndex(current: Int) -> Int {
        max(current - 1, noSelectionIndex)
    }

}
