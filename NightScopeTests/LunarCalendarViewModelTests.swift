import XCTest
import CoreLocation
@testable import NightScope

/// 既定の UserDefaults 保存先を使うと実際の逆ジオコーディングが走るため、メモリ上の保存先（東京）を使う。
@MainActor
private func makeInMemoryAppController() -> AppController {
    let storage = AppControllerTests.InMemoryLocationStorage()
    storage.latitude = 35.6762
    storage.longitude = 139.6503
    storage.name = "東京"
    storage.timeZoneIdentifier = TestTimeZones.tokyo.identifier
    let locationController = LocationController(
        storage: storage,
        searchService: AppControllerTests.NoopLocationSearchService(),
        locationNameResolver: AppControllerTests.FixedLocationNameResolver(
            details: ResolvedLocationDetails(name: "東京", timeZoneIdentifier: TestTimeZones.tokyo.identifier)
        )
    )
    return AppController(locationController: locationController, calculationService: MockNightCalculationService())
}

@MainActor
final class LunarCalendarViewModelTests: XCTestCase {

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func localDate(_ year: Int, _ month: Int, _ day: Int, in timeZone: TimeZone) -> Date {
        ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
            .date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeViewModel(
        today: Date,
        location: MockLocationController? = nil,
        onOpenNight: @escaping (Date) -> Void = { _ in }
    ) -> (LunarCalendarViewModel, MockLocationController) {
        let location = location ?? MockLocationController()
        if location.selectedTimeZone == .current {
            location.selectedTimeZone = tokyo
        }
        location.selectedLocation = CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)
        let viewModel = LunarCalendarViewModel(
            location: location,
            currentObservationDate: { today },
            onOpenNight: onOpenNight
        )
        return (viewModel, location)
    }

    private func month(of date: Date, in timeZone: TimeZone) -> (Int, Int) {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        return (calendar.component(.year, from: date), calendar.component(.month, from: date))
    }

    // MARK: - AC9

    func test_shiftMonth_twelveTimesReachesSameMonthNextYear() {
        let (viewModel, _) = makeViewModel(today: localDate(2026, 10, 13, in: tokyo))
        for _ in 0..<12 { viewModel.shiftMonth(by: 1) }
        XCTAssertTrue(month(of: viewModel.displayMonth, in: tokyo) == (2027, 10))
    }

    func test_days_leadingBlankCountMatchesFirstWeekday() {
        let (viewModel, _) = makeViewModel(today: localDate(2026, 10, 13, in: tokyo))
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
        for _ in 0..<13 {
            let firstDay = viewModel.days.compactMap { $0 }.first!
            let expectedBlanks = calendar.component(.weekday, from: firstDay.date) - 1
            XCTAssertEqual(viewModel.days.prefix { $0 == nil }.count, expectedBlanks)
            XCTAssertEqual(calendar.component(.day, from: firstDay.date), 1)
            viewModel.shiftMonth(by: 1)
        }
    }

    func test_shiftMonth_stopsAtSupportedRangeEdges() {
        let (upper, _) = makeViewModel(today: localDate(2100, 12, 10, in: tokyo))
        XCTAssertFalse(upper.canShiftForward)
        XCTAssertTrue(upper.canShiftBackward)
        upper.shiftMonth(by: 1)
        XCTAssertTrue(month(of: upper.displayMonth, in: tokyo) == (2100, 12))

        let (lower, _) = makeViewModel(today: localDate(1900, 1, 10, in: tokyo))
        XCTAssertFalse(lower.canShiftBackward)
        XCTAssertTrue(lower.canShiftForward)
        lower.shiftMonth(by: -1)
        XCTAssertTrue(month(of: lower.displayMonth, in: tokyo) == (1900, 1))
    }

    func test_goToToday_returnsToCurrentMonthAndSelectsToday() {
        let today = localDate(2026, 10, 13, in: tokyo)
        let (viewModel, _) = makeViewModel(today: today)
        viewModel.shiftMonth(by: 3)
        viewModel.select(localDate(2027, 1, 5, in: tokyo))
        viewModel.goToToday()
        XCTAssertTrue(month(of: viewModel.displayMonth, in: tokyo) == (2026, 10))
        XCTAssertEqual(viewModel.selectedNight, today)
        XCTAssertEqual(viewModel.selectedDay?.date, today)
    }

    // MARK: - AC10

    func test_openNight_passesSelectedNightToHandler() {
        var opened: Date?
        let night = localDate(2026, 10, 20, in: tokyo)
        let (viewModel, _) = makeViewModel(today: localDate(2026, 10, 13, in: tokyo)) { opened = $0 }
        viewModel.openNight(night)
        XCTAssertEqual(opened, night)
        XCTAssertEqual(viewModel.selectedNight, night)
    }

    func test_openNight_updatesDetailViewModelSelectedDateThroughRootDependencies() {
        let appController = makeInMemoryAppController()
        let dependencies = AppRootDependencies(appController: appController)
        let timeZone = appController.locationController.selectedTimeZone
        let night = ObservationTimeZone.startOfDay(
            for: Date().addingTimeInterval(3 * 86400),
            timeZone: timeZone
        )
        dependencies.lunarCalendarViewModel.openNight(night)
        XCTAssertEqual(dependencies.detailViewModel.selectedDate, night)
    }

    // MARK: - AC11

    func test_timeZoneChange_recomputesDays() {
        let location = MockLocationController()
        location.selectedTimeZone = tokyo
        let (viewModel, _) = makeViewModel(today: localDate(2026, 10, 13, in: tokyo), location: location)
        let tokyoFirstNight = viewModel.days.compactMap { $0 }.first!.date

        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        location.selectedTimeZone = losAngeles

        XCTAssertEqual(viewModel.timeZone, losAngeles)
        let firstNight = viewModel.days.compactMap { $0 }.first!.date
        XCTAssertNotEqual(firstNight, tokyoFirstNight)
        XCTAssertEqual(firstNight, localDate(2026, 10, 1, in: losAngeles))
        XCTAssertEqual(viewModel.days.compactMap { $0 }.count, 31)
    }

    func test_southernLatitude_setsHemisphereFlag() {
        let (viewModel, location) = makeViewModel(today: localDate(2026, 10, 13, in: tokyo))
        XCTAssertFalse(viewModel.isSouthernHemisphere)
        location.selectedLocation = CLLocationCoordinate2D(latitude: -33.87, longitude: 151.21)
        XCTAssertTrue(viewModel.isSouthernHemisphere)
    }
}
