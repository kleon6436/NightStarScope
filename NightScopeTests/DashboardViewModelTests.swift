import XCTest
import Combine
import CoreLocation
import MapKit
@testable import NightScope

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func test_reloadFavorites_initializesSelectionUpToMaxAndKeepsExisting() {
        let favorites = makeFavorites(count: 8)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()

        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        XCTAssertEqual(viewModel.selectedIDs, Set(favorites.prefix(DashboardViewModel.maxSelection).map(\.id)))

        let retainedID = favorites[2].id
        viewModel.selectedIDs = [retainedID, UUID()]
        viewModel.reloadFavorites()

        XCTAssertEqual(viewModel.selectedIDs, [retainedID])
    }

    func test_toggleSelection_respectsMaxLimit() {
        let favorites = makeFavorites(count: 7)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        let before = viewModel.selectedIDs
        let seventhID = favorites[6].id
        viewModel.toggleSelection(seventhID)
        XCTAssertEqual(viewModel.selectedIDs, before)

        let removableID = favorites[0].id
        viewModel.toggleSelection(removableID)
        XCTAssertFalse(viewModel.selectedIDs.contains(removableID))
    }

    func test_existingFavoriteNear_returnsMatchingWithin100m() {
        let favorite = makeFavorite(name: "Tokyo")
        let store = InMemoryFavoriteStore(favorites: [favorite])
        let viewModel = DashboardViewModel(comparisonController: StubComparisonController(), favoriteStore: store)

        let mapItem = makeTestMapItem(
            latitude: favorite.latitude + 0.0005,
            longitude: favorite.longitude + 0.0005,
            name: "Nearby"
        )

        XCTAssertEqual(viewModel.existingFavorite(near: mapItem)?.id, favorite.id)
    }

    func test_existingFavoriteNear_returnsNilBeyond100m() {
        let favorite = makeFavorite(name: "Tokyo")
        let store = InMemoryFavoriteStore(favorites: [favorite])
        let viewModel = DashboardViewModel(comparisonController: StubComparisonController(), favoriteStore: store)

        let mapItem = makeTestMapItem(
            latitude: favorite.latitude + 0.002,
            longitude: favorite.longitude + 0.002,
            name: "Far"
        )

        XCTAssertNil(viewModel.existingFavorite(near: mapItem))
    }

    func test_registerAndSelect_newLocation_addsToFavoritesAndSelectedIDs() {
        let store = InMemoryFavoriteStore(favorites: [])
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        let outcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 35.0, longitude: 135.0),
            name: "New Location",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        guard case let .registered(newID, swap) = outcome else {
            return XCTFail("Expected registered outcome")
        }

        XCTAssertNil(swap)
        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(store.favorites.first?.id, newID)
        XCTAssertEqual(viewModel.selectedIDs, [newID])
        XCTAssertEqual(viewModel.selectionOrder, [newID])
    }

    func test_registerAndSelect_alreadyExisted_addsExistingIDToSelectedIDs_withoutNewFavorite() {
        let favorite = makeFavorite(name: "Existing")
        let store = InMemoryFavoriteStore(favorites: [favorite])
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)
        viewModel.toggleSelection(favorite.id)

        let outcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: favorite.latitude, longitude: favorite.longitude),
            name: "Ignored",
            timeZoneIdentifier: favorite.timeZoneIdentifier
        )

        guard case let .alreadyExisted(existingID) = outcome else {
            return XCTFail("Expected alreadyExisted outcome")
        }

        XCTAssertEqual(existingID, favorite.id)
        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(viewModel.selectedIDs, [favorite.id])
        XCTAssertEqual(viewModel.selectionOrder, [favorite.id])
    }

    func test_registerAndSelect_atSelectionLimit_swapsOldestSelection() {
        let favorites = makeFavorites(count: 6)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        let outcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: 140.0),
            name: "Newest",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        guard case let .registered(newID, swap) = outcome else {
            return XCTFail("Expected registered outcome")
        }

        XCTAssertEqual(viewModel.selectedIDs.count, DashboardViewModel.maxSelection)
        XCTAssertFalse(viewModel.selectedIDs.contains(favorites[0].id))
        XCTAssertTrue(viewModel.selectedIDs.contains(newID))
        XCTAssertEqual(viewModel.selectionOrder.last, newID)
        XCTAssertEqual(swap?.removedID, favorites[0].id)
        XCTAssertEqual(swap?.addedID, newID)
    }

    func test_init_doesNotRefreshFromReplayedCurrentFavorites() async {
        let store = InMemoryFavoriteStore(favorites: makeFavorites(count: 3))
        let controller = StubComparisonController(matrix: .empty)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(controller.computeMatrixCalls, 0)
        XCTAssertEqual(viewModel.availableFavorites.count, 3)
    }

    func test_registerAndSelect_triggersSingleRefresh() async {
        let favorites = makeFavorites(count: 6)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController(matrix: .empty)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)
        try? await Task.sleep(for: .milliseconds(100))
        let beforeRefreshCalls = controller.computeMatrixCalls

        _ = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: 140.0),
            name: "Newest",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(controller.computeMatrixCalls, beforeRefreshCalls + 1)
    }

    func test_undoLastSwap_restoresPreviousSelection() {
        let favorites = makeFavorites(count: 6)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        let outcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: 140.0),
            name: "Newest",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        guard case let .registered(newID, swap) = outcome, let swap else {
            return XCTFail("Expected swap outcome")
        }

        viewModel.undoLastSwap()

        XCTAssertFalse(viewModel.selectedIDs.contains(newID))
        XCTAssertTrue(viewModel.selectedIDs.contains(swap.removedID))
        XCTAssertEqual(viewModel.selectionOrder.first, swap.removedID)
        XCTAssertNil(viewModel.lastSwap)
    }

    func test_undoLastSwap_restoresSwapsInLifoOrder() {
        let favorites = makeFavorites(count: 6)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        let firstOutcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: 140.0),
            name: "Newest 1",
            timeZoneIdentifier: "Asia/Tokyo"
        )
        let secondOutcome = viewModel.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 41.0, longitude: 141.0),
            name: "Newest 2",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        guard case let .registered(firstNewID, firstSwap?) = firstOutcome,
              case let .registered(secondNewID, secondSwap?) = secondOutcome else {
            return XCTFail("Expected swap outcomes")
        }

        viewModel.undoLastSwap()

        XCTAssertFalse(viewModel.selectedIDs.contains(secondNewID))
        XCTAssertTrue(viewModel.selectedIDs.contains(secondSwap.removedID))
        XCTAssertEqual(viewModel.lastSwap, firstSwap)

        viewModel.undoLastSwap()

        XCTAssertFalse(viewModel.selectedIDs.contains(firstNewID))
        XCTAssertTrue(viewModel.selectedIDs.contains(firstSwap.removedID))
        XCTAssertNil(viewModel.lastSwap)
    }

    func test_removeFavorite_removesFromStoreAndPrunesSelectedIDs() async {
        let favorites = makeFavorites(count: 3)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController(matrix: .empty)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        viewModel.removeFavorite(favorites[0].id)
        await Task.yield()

        XCTAssertEqual(store.favorites.map(\.id), [favorites[1].id, favorites[2].id])
        XCTAssertFalse(viewModel.selectedIDs.contains(favorites[0].id))
        XCTAssertFalse(viewModel.selectionOrder.contains(favorites[0].id))
    }

    func test_selectionOrder_isMaintainedOnToggleSelection() {
        let favorites = makeFavorites(count: 3)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController()
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        viewModel.toggleSelection(favorites[1].id)
        XCTAssertEqual(viewModel.selectionOrder, [favorites[0].id, favorites[2].id])

        viewModel.toggleSelection(favorites[1].id)
        XCTAssertEqual(viewModel.selectionOrder, [favorites[0].id, favorites[2].id, favorites[1].id])

        viewModel.toggleSelection(favorites[0].id)
        XCTAssertEqual(viewModel.selectionOrder, [favorites[2].id, favorites[1].id])
    }

    func test_sortedSelectedLocations_byScore_descendingWithNameTiebreak() async {
        let favorites = [
            makeFavorite(name: "Beta"),
            makeFavorite(name: "Alpha"),
            makeFavorite(name: "Gamma")
        ]
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = date1.addingTimeInterval(86_400)
        let matrix = makeMatrix(
            favorites: favorites,
            dates: [date1, date2],
            scores: [
                favorites[0].id: [5, 5],
                favorites[1].id: [10, 0],
                favorites[2].id: [4, 5]
            ]
        )
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))
        await viewModel.refresh(referenceDate: date1)

        let sortedNames = viewModel.sortedSelectedLocations().map(\.name)
        XCTAssertEqual(sortedNames, ["Alpha", "Beta", "Gamma"])
    }

    func test_sortedSelectedLocations_byName_ascending() {
        let favorites = [
            makeFavorite(name: "Tokyo"),
            makeFavorite(name: "Aomori"),
            makeFavorite(name: "Osaka")
        ]
        let viewModel = DashboardViewModel(comparisonController: StubComparisonController(), favoriteStore: InMemoryFavoriteStore(favorites: favorites))
        viewModel.sortKey = .name

        let sortedNames = viewModel.sortedSelectedLocations().map(\.name)
        XCTAssertEqual(sortedNames, ["Aomori", "Osaka", "Tokyo"])
    }

    func test_sortedSelectedLocations_byBestDate_ascendingWithNameTiebreak() async {
        let favorites = [
            makeFavorite(name: "Alpha"),
            makeFavorite(name: "Beta"),
            makeFavorite(name: "Gamma")
        ]
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = date1.addingTimeInterval(86_400)
        let matrix = makeMatrix(
            favorites: favorites,
            dates: [date1, date2],
            scores: [
                favorites[0].id: [1, 10],
                favorites[1].id: [9, 2],
                favorites[2].id: [1, 8]
            ]
        )
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))
        await viewModel.refresh(referenceDate: date1)
        viewModel.sortKey = .bestDate

        let sortedNames = viewModel.sortedSelectedLocations().map(\.name)
        XCTAssertEqual(sortedNames, ["Beta", "Alpha", "Gamma"])
    }

    func test_bestLocationID_returnsHighestScoringLocationForDate_withNameTiebreakOnTie() async {
        let favorites = [
            makeFavorite(name: "Beta"),
            makeFavorite(name: "Alpha"),
            makeFavorite(name: "Gamma")
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let matrix = makeMatrix(
            favorites: favorites,
            dates: [date],
            scores: [
                favorites[0].id: [10],
                favorites[1].id: [10],
                favorites[2].id: [8]
            ]
        )
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))
        await viewModel.refresh(referenceDate: date)

        XCTAssertEqual(viewModel.bestLocationID(for: date.addingTimeInterval(21_600)), favorites[1].id)
    }

    func test_bestLocationID_returnsNilWhenAllScoresNil() async {
        let favorites = [makeFavorite(name: "Alpha"), makeFavorite(name: "Beta")]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let matrix = makeMatrix(
            favorites: favorites,
            dates: [date],
            scores: [
                favorites[0].id: [nil],
                favorites[1].id: [nil]
            ]
        )
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))
        await viewModel.refresh(referenceDate: date)

        XCTAssertNil(viewModel.bestLocationID(for: date.addingTimeInterval(3_600)))
    }

    func test_refresh_whenWeatherFailedForAllLocations_setsLastError() async {
        let favorites = [makeFavorite(name: "Alpha"), makeFavorite(name: "Beta")]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var matrix = makeMatrix(favorites: favorites, dates: [date], scores: [:])
        matrix.weatherFailedLocationIDs = Set(favorites.map(\.id))
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))

        await viewModel.refresh(referenceDate: date)

        XCTAssertEqual(viewModel.lastError, L10n.tr("ダッシュボードのデータ取得に失敗しました"))
    }

    func test_refresh_whenWeatherFailedForSomeLocations_keepsLastErrorNil() async {
        let favorites = [makeFavorite(name: "Alpha"), makeFavorite(name: "Beta")]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var matrix = makeMatrix(favorites: favorites, dates: [date], scores: [:])
        matrix.weatherFailedLocationIDs = [favorites[0].id]
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: favorites))

        await viewModel.refresh(referenceDate: date)

        XCTAssertNil(viewModel.lastError)
    }

    /// セル選択では、列の日付（端末タイムゾーンの 0 時）ではなく地点の夜の日付を渡す。
    func test_selectionDate_returnsNightDateInLocationTimeZone() async {
        let tokyo = TestTimeZones.tokyo
        let favorite = FavoriteLocation(
            id: UUID(),
            name: "Tokyo",
            latitude: 35.0,
            longitude: 135.0,
            timeZoneIdentifier: tokyo.identifier,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let columnTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        let column = ObservationTimeZone.gregorianCalendar(timeZone: columnTimeZone)
            .date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let nightDate = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
            .date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let night = makeNightSummary(date: nightDate, timeZoneIdentifier: tokyo.identifier)
        let cell = ComparisonCell(locationID: favorite.id, date: column, nightSummary: night, loadState: .loaded)
        let matrix = ComparisonMatrix(
            locations: [favorite],
            dates: [column],
            cellsByID: [cell.id: cell],
            columnTimeZone: columnTimeZone
        )
        let controller = StubComparisonController(matrix: matrix)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: InMemoryFavoriteStore(favorites: [favorite]))
        await viewModel.refresh(referenceDate: column)

        XCTAssertEqual(viewModel.selectionDate(for: favorite.id, columnDate: column), nightDate)

        // 夜がまだないセルでも、列の年月日を地点のタイムゾーンで解釈する
        let emptyMatrix = ComparisonMatrix(locations: [favorite], dates: [column], cellsByID: [:], columnTimeZone: columnTimeZone)
        controller.matrix = emptyMatrix
        await viewModel.refresh(referenceDate: column)
        XCTAssertEqual(viewModel.selectionDate(for: favorite.id, columnDate: column), nightDate)
    }

    func test_refresh_callsControllerWithFilteredLocationsOnly() async {
        let favorites = makeFavorites(count: 3)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController(matrix: .empty)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        viewModel.selectedIDs = [favorites[0].id, favorites[2].id]
        await viewModel.refresh(referenceDate: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(controller.lastLocations?.map(\.id), [favorites[0].id, favorites[2].id])
    }

    func test_favoriteUpdates_pruneSelectionAndRefreshWhenSelectionRemains() async {
        let favorites = makeFavorites(count: 3)
        let store = InMemoryFavoriteStore(favorites: favorites)
        let controller = StubComparisonController(matrix: .empty)
        let viewModel = DashboardViewModel(comparisonController: controller, favoriteStore: store)

        viewModel.selectedIDs = [favorites[0].id, favorites[1].id]
        let beforeRefreshCalls = controller.computeMatrixCalls
        store.favorites = [favorites[0]]
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(viewModel.availableFavorites.map(\.id), [favorites[0].id])
        XCTAssertEqual(viewModel.selectedIDs, [favorites[0].id])
        XCTAssertGreaterThan(controller.computeMatrixCalls, beforeRefreshCalls)
    }

    /// 深夜 02:00（東京、日の出 04:58 前）の初回読み込みでは、読み込み中の列も先頭が進行中の前夜（8/12）になる。
    /// 計算結果の列（ComparisonController.makeDates）と同じ列なので、読み込み完了時に列がずれない。
    func test_initialLoadingMatrix_afterLocalMidnight_startsAtPreviousNight() async {
        let tokyo = TestTimeZones.tokyo
        let afterMidnight = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
            .date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 2))!
        let favorite = FavoriteLocation(
            id: UUID(),
            name: "Tokyo",
            latitude: 35.6762,
            longitude: 139.6503,
            timeZoneIdentifier: tokyo.identifier,
            createdAt: afterMidnight
        )
        let controller = SuspendingComparisonController()
        let viewModel = DashboardViewModel(
            comparisonController: controller,
            favoriteStore: InMemoryFavoriteStore(favorites: [favorite])
        )
        // 購読直後の現在値では更新しないため、基準時刻を固定した更新が初回の計算になる
        let refresh = Task { await viewModel.refresh(referenceDate: afterMidnight) }
        await waitUntil { controller.computeMatrixCalls >= 1 }

        XCTAssertTrue(viewModel.isInitialLoad)
        let matrix = viewModel.matrix
        let columnCalendar = ObservationTimeZone.gregorianCalendar(timeZone: matrix.columnTimeZone)
        XCTAssertEqual(matrix.dates.count, DashboardViewModel.dayCount)
        XCTAssertEqual(
            matrix.dates.first.map { columnCalendar.dateComponents([.year, .month, .day], from: $0) },
            DateComponents(year: 2026, month: 8, day: 12)
        )
        XCTAssertEqual(
            matrix.dates,
            ComparisonController.makeDates(
                referenceDate: afterMidnight,
                dayCount: DashboardViewModel.dayCount,
                timeZone: matrix.columnTimeZone,
                locations: [favorite]
            )
        )
        XCTAssertEqual(
            matrix.cellsByID[ComparisonCell.makeID(locationID: favorite.id, date: matrix.dates[0])]?.loadState,
            .loading
        )

        controller.resume()
        await refresh.value
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件を満たすまでにタイムアウトしました", file: file, line: line)
    }

    private func makeFavorites(count: Int) -> [FavoriteLocation] {
        (0..<count).map { index in
            FavoriteLocation(
                id: UUID(),
                name: String(format: "Location %02d", index + 1),
                latitude: Double(index),
                longitude: Double(index),
                timeZoneIdentifier: TimeZone.current.identifier,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
    }

    private func makeFavorite(name: String) -> FavoriteLocation {
        FavoriteLocation(
            id: UUID(),
            name: name,
            latitude: 35.0,
            longitude: 135.0,
            timeZoneIdentifier: TimeZone.current.identifier,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeMatrix(
        favorites: [FavoriteLocation],
        dates: [Date],
        scores: [UUID: [Int?]]
    ) -> ComparisonMatrix {
        var cellsByID: [String: ComparisonCell] = [:]
        for favorite in favorites {
            for (index, date) in dates.enumerated() {
                let score = scores[favorite.id]?[index]
                let indexValue = score.map {
                    StarGazingIndex(
                        score: $0,
                        milkyWayScore: 0,
                        constellationScore: 0,
                        weatherScore: 0,
                        lightPollutionScore: 0,
                        hasWeatherData: true,
                        hasLightPollutionData: true
                    )
                }
                let cell = ComparisonCell(
                    locationID: favorite.id,
                    date: date,
                    index: indexValue,
                    loadState: .loaded
                )
                cellsByID[cell.id] = cell
            }
        }
        // 列の暦日判定（bestLocationID など）が端末のタイムゾーンに依存しないよう固定する。
        return ComparisonMatrix(
            locations: favorites,
            dates: dates,
            cellsByID: cellsByID,
            columnTimeZone: TestTimeZones.tokyo
        )
    }
}

/// `resume()` を呼ぶまで計算を終えない比較コントローラ。読み込み中の行列を観察するために使う。
@MainActor
private final class SuspendingComparisonController: ComparisonControlling {
    var matrix: ComparisonMatrix = .empty
    var dayCount: Int = DashboardViewModel.dayCount
    private(set) var computeMatrixCalls = 0
    private var isSuspended = true

    func resume() {
        isSuspended = false
    }

    func refresh(referenceDate: Date, locations: [FavoriteLocation]?) async {}

    func computeMatrix(referenceDate: Date, locations: [FavoriteLocation]?) async -> ComparisonMatrix {
        computeMatrixCalls += 1
        while isSuspended && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return matrix
    }
}
