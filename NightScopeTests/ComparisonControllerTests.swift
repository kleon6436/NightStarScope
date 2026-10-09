import XCTest
import Combine
import CoreLocation
@testable import NightScope

@MainActor
final class ComparisonControllerTests: XCTestCase {
    func test_refresh_buildsCellsForFavoriteLocations() async {
        // 2023-11-15 07:13 JST。東京の日の出（約 06:17）の後なので、観測日（先頭列）は 11/15。
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let favorite = FavoriteLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo")
        let store = InMemoryFavoriteStore(favorites: [favorite])
        let weatherService = MockComparisonWeatherService()
        let lightPollutionService = MockLightPollutionService(bortleByCoordinate: ["35.6762,139.6503": 3.0])
        let calculationService = MockNightCalculationService()
        // セルは列と同じ年月日の夜で対応付く。先頭列は端末のタイムゾーンによらず東京の観測日になる。
        let night1 = makeNightSummary(date: tokyoDay(2023, 11, 15), withWindow: true, timeZoneIdentifier: "Asia/Tokyo")
        let night2 = makeNightSummary(date: tokyoDay(2023, 11, 16), withWindow: true, timeZoneIdentifier: "Asia/Tokyo")
        await calculationService.enqueueUpcomingNights([night1, night2])
        weatherService.resultByLocationKey["35.6762,139.6503|Asia/Tokyo"] = weatherService.makeResult(
            dates: [night1.date, night2.date],
            timeZone: TestTimeZones.tokyo
        )

        let controller = ComparisonController(
            favoriteStore: store,
            weatherService: weatherService,
            lightPollutionService: lightPollutionService,
            calculationService: calculationService
        )
        controller.dayCount = 2
        await controller.refresh(referenceDate: baseDate)

        XCTAssertEqual(controller.matrix.locations.count, 1)
        XCTAssertEqual(controller.matrix.dates.count, 2)
        XCTAssertEqual(columnDay(controller.matrix.dates[0], in: controller.matrix), DateComponents(year: 2023, month: 11, day: 15))
        XCTAssertEqual(controller.cell(for: favorite.id, date: controller.matrix.dates[0])?.loadState, .loaded)
        XCTAssertNotNil(controller.cell(for: favorite.id, date: controller.matrix.dates[0])?.index)
        XCTAssertEqual(controller.cell(for: favorite.id, date: controller.matrix.dates[0])?.nightSummary?.date, night1.date)
        XCTAssertEqual(controller.cell(for: favorite.id, date: controller.matrix.dates[1])?.nightSummary?.date, night2.date)
    }

    func test_bestCell_returnsHighestScoreForDate() async {
        // 2023-11-16 11:00 JST（日中）なので、観測日（先頭列）は 11/16。
        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)
        let favorites = [
            FavoriteLocation(name: "Dark", latitude: 35.0, longitude: 135.0, timeZoneIdentifier: "Asia/Tokyo"),
            FavoriteLocation(name: "Bright", latitude: 34.0, longitude: 135.0, timeZoneIdentifier: "Asia/Tokyo")
        ]
        let store = InMemoryFavoriteStore(favorites: favorites)
        let weatherService = MockComparisonWeatherService()
        let lightPollutionService = MockLightPollutionService(
            bortleByCoordinate: ["35.0000,135.0000": 3.0, "34.0000,135.0000": 7.0]
        )
        let calculationService = MockNightCalculationService()
        let nightDate = tokyoDay(2023, 11, 16)
        let darkNight = makeNightSummary(date: nightDate, withWindow: true, timeZoneIdentifier: "Asia/Tokyo")
        let brightNight = makeNightSummary(date: nightDate, withWindow: true, timeZoneIdentifier: "Asia/Tokyo")
        await calculationService.enqueueUpcomingNights([darkNight])
        await calculationService.enqueueUpcomingNights([brightNight])
        let tz = TestTimeZones.tokyo
        weatherService.resultByLocationKey["35.0000,135.0000|Asia/Tokyo"] = weatherService.makeResult(dates: [darkNight.date], timeZone: tz)
        weatherService.resultByLocationKey["34.0000,135.0000|Asia/Tokyo"] = weatherService.makeResult(dates: [brightNight.date], timeZone: tz)

        let controller = ComparisonController(
            favoriteStore: store,
            weatherService: weatherService,
            lightPollutionService: lightPollutionService,
            calculationService: calculationService
        )
        controller.dayCount = 1
        await controller.refresh(referenceDate: baseDate)

        XCTAssertEqual(controller.cell(for: favorites[0].id, date: controller.matrix.dates[0])?.loadState, .loaded)
        XCTAssertEqual(controller.cell(for: favorites[1].id, date: controller.matrix.dates[0])?.loadState, .loaded)
        XCTAssertEqual(controller.bestCell(for: controller.matrix.dates[0])?.locationID, favorites[0].id)
    }

    func test_refresh_usesReferenceDateForPartialWeatherCoverage() async {
        let tokyo = TestTimeZones.tokyo
        let dayStart = ObservationTimeZone.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000), timeZone: tokyo)
        let (night, weather) = makePartiallyCoveredNight(dayStart: dayStart, timeZone: tokyo)

        func refreshedIndex(referenceDate: Date) async -> StarGazingIndex? {
            let favorite = FavoriteLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo")
            let weatherService = MockComparisonWeatherService()
            weatherService.resultByLocationKey["35.6762,139.6503|Asia/Tokyo"] = WeatherFetchResult(
                weatherByDate: [weatherService.dateKey(dayStart, timeZone: tokyo): weather],
                errorMessage: nil,
                lastModifiedDate: nil,
                locationKey: "",
                timeZoneIdentifier: tokyo.identifier
            )
            let calculationService = MockNightCalculationService()
            await calculationService.enqueueUpcomingNights([night])
            let controller = ComparisonController(
                favoriteStore: InMemoryFavoriteStore(favorites: [favorite]),
                weatherService: weatherService,
                lightPollutionService: MockLightPollutionService(bortleByCoordinate: ["35.6762,139.6503": 3.0]),
                calculationService: calculationService
            )
            // 先頭列は参照日時の東京の観測日。当日を含む余裕を持たせて 4 日分の列を作る
            controller.dayCount = 4
            await controller.refresh(referenceDate: referenceDate)
            guard let column = controller.matrix.dates.first(where: {
                ObservationTimeZone.preservingCalendarDay($0, from: controller.matrix.columnTimeZone, to: tokyo) == dayStart
            }) else {
                XCTFail("東京の当日に対応する列がない")
                return nil
            }
            return controller.cell(for: favorite.id, date: column)?.index
        }

        let todayIndex = await refreshedIndex(referenceDate: dayStart.addingTimeInterval(12 * 3600))
        // 参照日時がその夜の「今日」でなければ、一部しか覆わない天気は使わない
        let otherDayIndex = await refreshedIndex(referenceDate: dayStart.addingTimeInterval(-36 * 3600))

        XCTAssertEqual(todayIndex?.hasWeatherData, true)
        XCTAssertEqual(otherDayIndex?.hasWeatherData, false)
    }

    /// 時差の大きい地点同士でも、各列にはその地点のタイムゾーンで同じ年月日の夜が入る。
    func test_computeMatrix_pairsNightsByLocalCalendarDayAcrossTimeZones() async {
        let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!  // UTC+14
        let pagoPago = TimeZone(identifier: "Pacific/Pago_Pago")!     // UTC-11
        let favorites = [
            FavoriteLocation(name: "East", latitude: 1.87, longitude: -157.4, timeZoneIdentifier: kiritimati.identifier),
            FavoriteLocation(name: "West", latitude: -14.27, longitude: -170.7, timeZoneIdentifier: pagoPago.identifier)
        ]
        let controller = ComparisonController(
            favoriteStore: InMemoryFavoriteStore(favorites: favorites),
            weatherService: MockComparisonWeatherService(),
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: [:]),
            calculationService: DailyNightCalculationService()
        )
        controller.dayCount = 3

        let matrix = await controller.computeMatrix(referenceDate: referenceDate, locations: favorites)

        let columnCalendar = ObservationTimeZone.gregorianCalendar(timeZone: matrix.columnTimeZone)
        XCTAssertEqual(matrix.dates.count, 3)
        for date in matrix.dates {
            let columnDay = columnCalendar.dateComponents([.year, .month, .day], from: date)
            for favorite in favorites {
                let timeZone = TimeZone(identifier: favorite.timeZoneIdentifier)!
                guard let night = matrix.cellsByID[ComparisonCell.makeID(locationID: favorite.id, date: date)]?.nightSummary else {
                    XCTFail("\(favorite.name) の \(columnDay) の夜がない")
                    continue
                }
                let nightDay = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
                    .dateComponents([.year, .month, .day], from: night.date)
                XCTAssertEqual(nightDay, columnDay, "\(favorite.name) の夜が列の暦日とずれている")
            }
        }
    }

    func test_computeMatrix_recordsLocationsWhoseWeatherFetchFailed() async {
        let tokyo = TestTimeZones.tokyo
        let favorites = [
            FavoriteLocation(name: "Failed", latitude: 35.0, longitude: 135.0, timeZoneIdentifier: tokyo.identifier),
            FavoriteLocation(name: "Loaded", latitude: 34.0, longitude: 135.0, timeZoneIdentifier: tokyo.identifier)
        ]
        let weatherService = MockComparisonWeatherService()
        weatherService.resultByLocationKey["35.0000,135.0000|Asia/Tokyo"] = WeatherFetchResult(
            weatherByDate: [:],
            errorMessage: "オフライン",
            lastModifiedDate: nil,
            locationKey: "",
            timeZoneIdentifier: tokyo.identifier
        )
        let controller = ComparisonController(
            favoriteStore: InMemoryFavoriteStore(favorites: favorites),
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: [:]),
            calculationService: DailyNightCalculationService()
        )
        controller.dayCount = 1

        let matrix = await controller.computeMatrix(referenceDate: Date(timeIntervalSince1970: 1_790_000_000), locations: favorites)

        XCTAssertEqual(matrix.weatherFailedLocationIDs, [favorites[0].id])
    }

    /// 東京の指定日の 0 時。
    private func tokyoDay(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        ObservationTimeZone.gregorianCalendar(timeZone: TestTimeZones.tokyo)
            .date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 列の日付が表す暦日（列のタイムゾーンでの年月日）。
    private func columnDay(_ date: Date, in matrix: ComparisonMatrix) -> DateComponents {
        ObservationTimeZone.gregorianCalendar(timeZone: matrix.columnTimeZone)
            .dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - 先頭列は各地点の観測日（深夜〜明け方は進行中の前夜）

    /// 東京の 02:00（8/13 の日の出 04:58 より前）は、先頭列が進行中の前夜（8/12）になる。
    /// 列のタイムゾーン（端末）によらず、地点の観測日の年月日がそのまま先頭列の暦日になる。
    func test_makeDates_afterLocalMidnightBeforeSunrise_startsAtPreviousNight() {
        let tokyo = FavoriteLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo")
        let afterMidnight = tokyoDay(2026, 8, 13, hour: 2)
        let afterSunrise = tokyoDay(2026, 8, 13, hour: 7)

        for columnTimeZone in [TestTimeZones.tokyo, TimeZone(identifier: "America/Los_Angeles")!, TimeZone(identifier: "UTC")!] {
            let calendar = ObservationTimeZone.gregorianCalendar(timeZone: columnTimeZone)
            func day(_ date: Date) -> DateComponents { calendar.dateComponents([.year, .month, .day], from: date) }

            let nightDates = ComparisonController.makeDates(
                referenceDate: afterMidnight,
                dayCount: 3,
                timeZone: columnTimeZone,
                locations: [tokyo]
            )
            XCTAssertEqual(nightDates.map(day), [
                DateComponents(year: 2026, month: 8, day: 12),
                DateComponents(year: 2026, month: 8, day: 13),
                DateComponents(year: 2026, month: 8, day: 14)
            ], columnTimeZone.identifier)
            XCTAssertEqual(nightDates.first, calendar.startOfDay(for: nightDates[0]), columnTimeZone.identifier)

            let morningDates = ComparisonController.makeDates(
                referenceDate: afterSunrise,
                dayCount: 1,
                timeZone: columnTimeZone,
                locations: [tokyo]
            )
            XCTAssertEqual(morningDates.map(day), [DateComponents(year: 2026, month: 8, day: 13)], columnTimeZone.identifier)
        }

        // 地点がなければ列のタイムゾーンの暦日の今日から始める
        let tokyoCalendar = ObservationTimeZone.gregorianCalendar(timeZone: TestTimeZones.tokyo)
        XCTAssertEqual(
            ComparisonController.makeDates(referenceDate: afterMidnight, dayCount: 1, timeZone: TestTimeZones.tokyo),
            [tokyoCalendar.startOfDay(for: afterMidnight)]
        )
    }

    /// 深夜 02:00 のダッシュボードでは、先頭列に進行中の前夜（8/12 の夜）が入る。
    func test_computeMatrix_afterLocalMidnight_firstColumnIsInProgressNight() async {
        let favorite = FavoriteLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo")
        let controller = ComparisonController(
            favoriteStore: InMemoryFavoriteStore(favorites: [favorite]),
            weatherService: MockComparisonWeatherService(),
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: [:]),
            calculationService: DailyNightCalculationService()
        )
        controller.dayCount = 2

        let matrix = await controller.computeMatrix(referenceDate: tokyoDay(2026, 8, 13, hour: 2), locations: [favorite])

        XCTAssertEqual(matrix.dates.map { columnDay($0, in: matrix) }, [
            DateComponents(year: 2026, month: 8, day: 12),
            DateComponents(year: 2026, month: 8, day: 13)
        ])
        let firstCell = matrix.cellsByID[ComparisonCell.makeID(locationID: favorite.id, date: matrix.dates[0])]
        XCTAssertEqual(firstCell?.loadState, .loaded)
        XCTAssertEqual(firstCell?.nightSummary?.date, tokyoDay(2026, 8, 12))
    }

    /// 地点ごとに観測日が異なる場合は、最も早い観測日から列を始める。
    /// 1_790_000_000（2026-09-21 14:13 UTC）は、パゴパゴ 09-21 03:13（日の出 06:13 前 → 観測日 09-20）、
    /// キリティマティ 09-22 04:13（日の出 06:20 前 → 観測日 09-21）。
    func test_computeMatrix_startsAtEarliestObservationDateAmongLocations() async {
        let favorites = [
            FavoriteLocation(name: "East", latitude: 1.87, longitude: -157.4, timeZoneIdentifier: "Pacific/Kiritimati"),
            FavoriteLocation(name: "West", latitude: -14.27, longitude: -170.7, timeZoneIdentifier: "Pacific/Pago_Pago")
        ]
        let controller = ComparisonController(
            favoriteStore: InMemoryFavoriteStore(favorites: favorites),
            weatherService: MockComparisonWeatherService(),
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: [:]),
            calculationService: DailyNightCalculationService()
        )
        controller.dayCount = 2

        let matrix = await controller.computeMatrix(referenceDate: Date(timeIntervalSince1970: 1_790_000_000), locations: favorites)

        XCTAssertEqual(matrix.dates.map { columnDay($0, in: matrix) }, [
            DateComponents(year: 2026, month: 9, day: 20),
            DateComponents(year: 2026, month: 9, day: 21)
        ])
        // 東側（キリティマティ）の進行中の夜（09-21）も 2 列目に入る
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        let eastNight = matrix.cellsByID[ComparisonCell.makeID(locationID: favorites[0].id, date: matrix.dates[1])]?.nightSummary
        XCTAssertEqual(
            eastNight.map { ObservationTimeZone.gregorianCalendar(timeZone: kiritimati).dateComponents([.year, .month, .day], from: $0.date) },
            DateComponents(year: 2026, month: 9, day: 21)
        )
    }

    func test_refresh_withNoFavorites_keepsMatrixEmpty() async {
        let controller = ComparisonController(
            favoriteStore: InMemoryFavoriteStore(favorites: []),
            weatherService: MockComparisonWeatherService(),
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: [:]),
            calculationService: MockNightCalculationService()
        )

        await controller.refresh(referenceDate: Date())

        XCTAssertTrue(controller.matrix.locations.isEmpty)
        XCTAssertTrue(controller.matrix.cellsByID.isEmpty)
    }
}

/// 要求された開始日から 1 日ずつ、そのタイムゾーンの 0 時を日付とする夜を返す。
private struct DailyNightCalculationService: NightCalculating {
    func calculateNightSummary(date: Date, location: CLLocationCoordinate2D, timeZone: TimeZone) async -> NightSummary {
        makeNightSummary(date: ObservationTimeZone.startOfDay(for: date, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier)
    }

    func calculateUpcomingNights(
        from date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int
    ) async -> [NightSummary] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let start = calendar.startOfDay(for: date)
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map {
                makeNightSummary(date: calendar.startOfDay(for: $0), timeZoneIdentifier: timeZone.identifier)
            }
        }
    }
}

@MainActor
private final class MockComparisonWeatherService: WeatherProviding {
    @Published var weatherByDate: [String: DayWeatherSummary] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentTemperatureCelsius: Double?
    var resultByLocationKey: [String: WeatherFetchResult] = [:]

    var weatherByDatePublisher: Published<[String: DayWeatherSummary]>.Publisher { $weatherByDate }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
    var errorMessagePublisher: AnyPublisher<String?, Never> { $errorMessage.eraseToAnyPublisher() }
    var currentTemperaturePublisher: AnyPublisher<Double?, Never> { $currentTemperatureCelsius.eraseToAnyPublisher() }

    func fetchWeather(latitude: Double, longitude: Double, timeZone: TimeZone) async {}
    func summary(for date: Date) -> DayWeatherSummary? { weatherByDate[dateKey(date, timeZone: .current)] }

    func fetchWeatherSnapshot(latitude: Double, longitude: Double, timeZone: TimeZone) async -> WeatherFetchResult {
        let locationKey = String(format: "%.4f,%.4f|%@", latitude, longitude, timeZone.identifier)
        return resultByLocationKey[locationKey] ?? WeatherFetchResult(
            weatherByDate: [:],
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: locationKey,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    func applyFetchResult(_ result: WeatherFetchResult) {
        weatherByDate = result.weatherByDate
        errorMessage = result.errorMessage
    }

    func summary(for date: Date, from weatherByDate: [String : DayWeatherSummary], timeZone: TimeZone) -> DayWeatherSummary? {
        weatherByDate[dateKey(date, timeZone: timeZone)]
    }

    func isForecastOutOfRange(for date: Date, in weatherByDate: [String : DayWeatherSummary], timeZone: TimeZone) -> Bool { false }

    func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func prepareForLocationChange(latitude: Double, longitude: Double, timeZone: TimeZone) {}

    func makeResult(dates: [Date], timeZone: TimeZone) -> WeatherFetchResult {
        let values = Dictionary(uniqueKeysWithValues: dates.map { date in
            let weather = DayWeatherSummary(date: date, nighttimeHours: [
                HourlyWeather(
                    date: date,
                    temperatureCelsius: 15,
                    cloudCoverPercent: 10,
                    precipitationMM: 0,
                    windSpeedKmh: 5,
                    humidityPercent: 40,
                    dewpointCelsius: 2,
                    weatherCode: 0,
                    visibilityMeters: 20_000,
                    windGustsKmh: 10,
                    windSpeedKmh500hpa: nil
                )
            ])
            return (dateKey(date, timeZone: timeZone), weather)
        })
        return WeatherFetchResult(
            weatherByDate: values,
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: "",
            timeZoneIdentifier: timeZone.identifier
        )
    }
}
