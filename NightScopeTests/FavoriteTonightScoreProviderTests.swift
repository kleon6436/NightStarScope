import XCTest
import Combine
import CoreLocation
@testable import NightScope

@MainActor
final class FavoriteTonightScoreProviderTests: XCTestCase {
    /// 2023-11-15 07:13 JST。テストの地点（北緯 30〜37°、東経 135〜136°）はいずれも日の出（06:38 まで）の後なので、
    /// 「今夜」は東京の 11/15 の夜になる（端末のタイムゾーンにはよらない）。
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func test_refreshIfNeeded_skipsFavoritesWithFreshCache() async {
        let favorite = makeFavorite(name: "Tokyo", latitude: 35.0, longitude: 135.0)
        let weatherService = MockTonightWeatherService()
        let calculationService = MockNightCalculationService()
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        weatherService.register(favorite: favorite, dates: [baseDate])

        var now = baseDate
        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: ["35.0000,135.0000": 3.0]),
            calculationService: calculationService,
            referenceDateProvider: { now }
        )

        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertNotNil(provider.score(for: favorite.id))
        XCTAssertEqual(weatherService.fetchCount, 1)

        // TTL 内なので再計算されない。
        now = baseDate.addingTimeInterval(FavoriteTonightScoreProvider.cacheLifetime - 1)
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 1)

        // TTL を超えると再計算される。
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        now = baseDate.addingTimeInterval(FavoriteTonightScoreProvider.cacheLifetime + 1)
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 2)
    }

    func test_refreshIfNeeded_scoresEveryFavoriteInOneRefresh() async {
        let favorites = (0..<8).map { offset in
            makeFavorite(name: "Loc\(offset)", latitude: 30.0 + Double(offset), longitude: 135.0)
        }
        let weatherService = MockTonightWeatherService()
        let calculationService = MockNightCalculationService()
        for favorite in favorites {
            weatherService.register(favorite: favorite, dates: [baseDate])
            await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        }

        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { self.baseDate }
        )

        await provider.refreshIfNeeded(favorites: favorites)

        XCTAssertEqual(weatherService.fetchCount, favorites.count)
        XCTAssertEqual(provider.scoresByFavoriteID.count, favorites.count)
        for favorite in favorites {
            XCTAssertNotNil(provider.score(for: favorite.id), "\(favorite.name) のスコアが計算されていない")
        }
        XCTAssertFalse(provider.isRefreshing)
    }

    func test_refreshIfNeeded_failureForOneFavoriteKeepsOthers() async {
        let failing = makeFavorite(name: "Failing", latitude: 35.0, longitude: 135.0)
        let succeeding = makeFavorite(name: "Succeeding", latitude: 36.0, longitude: 136.0)
        let weatherService = MockTonightWeatherService()
        weatherService.register(favorite: succeeding, dates: [baseDate])
        let calculationService = MockNightCalculationService()
        // 1 件目は夜間サマリーが得られず失敗扱いになる。
        await calculationService.enqueueUpcomingNights([])
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])

        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(bortleByCoordinate: ["36.0000,136.0000": 2.0]),
            calculationService: calculationService,
            referenceDateProvider: { self.baseDate }
        )

        await provider.refreshIfNeeded(favorites: [failing, succeeding])

        XCTAssertNil(provider.score(for: failing.id))
        let score = provider.score(for: succeeding.id)
        XCTAssertNotNil(score)
        XCTAssertEqual(score?.bortleClass, 2.0)
        XCTAssertEqual(score?.computedAt, baseDate)
    }

    // MARK: - 「今夜」は地点ごとの観測日（深夜〜明け方は進行中の前夜）

    /// 東京の 02:00（日の出 04:59 前）は、進行中の前夜（8/12 の夜）を「今夜」として採点する。
    func test_refreshIfNeeded_afterLocalMidnight_scoresInProgressPreviousNight() async {
        let tokyo = TestTimeZones.tokyo
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 2))!
        let previousNight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let favorite = makeFavorite(name: "Tokyo", latitude: 35.6762, longitude: 139.6503)
        let calculationService = RecordingTonightCalculationService()
        let provider = FavoriteTonightScoreProvider(
            weatherService: MockTonightWeatherService(),
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { afterMidnight }
        )

        await provider.refreshIfNeeded(favorites: [favorite])

        let requests = await calculationService.requests
        XCTAssertEqual(requests.map(\.from), [previousNight])
        XCTAssertNotNil(provider.score(for: favorite.id))
    }

    /// 時差のある地点を同時に更新しても、各地点はそれぞれの観測日の夜で採点する。
    /// 2026-08-13 01:00 UTC は東京 8/13 10:00（観測日 8/13）、ロサンゼルス 8/12 18:00（日没前 → 観測日 8/12）。
    /// まとめて 1 列にすると東京は終わった 8/12 の夜で採点されてしまう。
    func test_refreshIfNeeded_favoritesInDifferentTimeZones_eachUseOwnObservationNight() async {
        let tokyoTimeZone = TestTimeZones.tokyo
        let losAngelesTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        let referenceDate = Date(timeIntervalSince1970: 1_786_582_800)
        let tokyo = makeFavorite(name: "Tokyo", latitude: 35.6762, longitude: 139.6503)
        let losAngeles = FavoriteLocation(
            name: "Los Angeles",
            latitude: 34.0522,
            longitude: -118.2437,
            timeZoneIdentifier: losAngelesTimeZone.identifier,
            createdAt: baseDate
        )
        let calculationService = RecordingTonightCalculationService()
        let provider = FavoriteTonightScoreProvider(
            weatherService: MockTonightWeatherService(),
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { referenceDate }
        )

        await provider.refreshIfNeeded(favorites: [tokyo, losAngeles])

        let requests = await calculationService.requests
        let tokyoNight = ObservationTimeZone.gregorianCalendar(timeZone: tokyoTimeZone)
            .date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let losAngelesNight = ObservationTimeZone.gregorianCalendar(timeZone: losAngelesTimeZone)
            .date(from: DateComponents(year: 2026, month: 8, day: 12))!
        XCTAssertEqual(requests.first { $0.timeZoneIdentifier == tokyoTimeZone.identifier }?.from, tokyoNight)
        XCTAssertEqual(requests.first { $0.timeZoneIdentifier == losAngelesTimeZone.identifier }?.from, losAngelesNight)
        XCTAssertNotNil(provider.score(for: tokyo.id))
        XCTAssertNotNil(provider.score(for: losAngeles.id))
    }

    func test_refreshIfNeeded_weatherFailureIsNotCachedAndKeepsPreviousValue() async {
        let favorite = makeFavorite(name: "Flaky", latitude: 35.0, longitude: 135.0)
        let weatherService = MockTonightWeatherService()
        let calculationService = MockNightCalculationService()
        weatherService.registerFailure(favorite: favorite)
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])

        var now = baseDate
        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { now }
        )

        // 天気取得に失敗した地点はスコアを保存しない（バックオフ後の更新で再取得される）。
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertNil(provider.score(for: favorite.id))
        now = baseDate.addingTimeInterval(FavoriteTonightScoreProvider.failureRetryInterval + 1)

        // 成功した値は、その後の失敗で上書きされない。
        weatherService.register(favorite: favorite, dates: [baseDate])
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        await provider.refreshIfNeeded(favorites: [favorite])
        let stored = provider.score(for: favorite.id)
        XCTAssertNotNil(stored)

        weatherService.registerFailure(favorite: favorite)
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        await provider.refreshIfNeeded(favorites: [favorite], force: true)
        XCTAssertEqual(provider.score(for: favorite.id), stored)
    }

    func test_refreshIfNeeded_failedFavoriteIsNotRetriedWithinBackoffUnlessForced() async {
        let favorite = makeFavorite(name: "Flaky", latitude: 35.0, longitude: 135.0)
        let weatherService = MockTonightWeatherService()
        let calculationService = MockNightCalculationService()
        weatherService.registerFailure(favorite: favorite)

        var now = baseDate
        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { now }
        )

        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 1)

        now = baseDate.addingTimeInterval(FavoriteTonightScoreProvider.failureRetryInterval - 1)
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 1, "バックオフ中は再試行しない")

        await provider.refreshIfNeeded(favorites: [favorite], force: true)
        XCTAssertEqual(weatherService.fetchCount, 2, "force ならバックオフを無視する")

        now = baseDate.addingTimeInterval(FavoriteTonightScoreProvider.failureRetryInterval * 3)
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 3, "バックオフ後は再試行する")
    }

    func test_refreshIfNeeded_failureDropsEntryFromPreviousObservationNight() async {
        let favorite = makeFavorite(name: "Tokyo", latitude: 35.0, longitude: 135.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestTimeZones.tokyo
        let nov14 = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14)) ?? baseDate
        let beforeSunrise = calendar.date(
            from: DateComponents(year: 2023, month: 11, day: 15, hour: 5, minute: 50)
        ) ?? baseDate
        let afterSunrise = calendar.date(
            from: DateComponents(year: 2023, month: 11, day: 15, hour: 6, minute: 40)
        ) ?? baseDate

        let weatherService = MockTonightWeatherService()
        weatherService.register(favorite: favorite, dates: [nov14])
        let calculationService = MockNightCalculationService()
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: nov14, withWindow: true)])

        var now = beforeSunrise
        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { now }
        )
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertNotNil(provider.score(for: favorite.id))

        // 観測夜が切り替わった後に取得が失敗したら、前の夜の値を「今夜」として残さない。
        weatherService.registerFailure(favorite: favorite)
        now = afterSunrise
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertNil(provider.score(for: favorite.id))
    }

    func test_refreshIfNeeded_prunesRemovedFavorites() async {
        let kept = makeFavorite(name: "Kept", latitude: 35.0, longitude: 135.0)
        let removed = makeFavorite(name: "Removed", latitude: 36.0, longitude: 136.0)
        let weatherService = MockTonightWeatherService()
        let calculationService = MockNightCalculationService()
        for favorite in [kept, removed] {
            weatherService.register(favorite: favorite, dates: [baseDate])
            await calculationService.enqueueUpcomingNights([makeNightSummary(date: baseDate, withWindow: true)])
        }

        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { self.baseDate }
        )

        await provider.refreshIfNeeded(favorites: [kept, removed])
        XCTAssertNotNil(provider.score(for: removed.id))

        await provider.refreshIfNeeded(favorites: [kept])
        XCTAssertNil(provider.score(for: removed.id))
        XCTAssertNotNil(provider.score(for: kept.id))
        XCTAssertEqual(provider.scoresByFavoriteID.count, 1)
    }

    func test_refreshIfNeeded_recomputesWhenObservationNightRollsOverWithinTTL() async {
        let favorite = makeFavorite(name: "Tokyo", latitude: 35.0, longitude: 135.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TestTimeZones.tokyo
        let nov14 = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14)) ?? baseDate
        let nov15 = calendar.date(from: DateComponents(year: 2023, month: 11, day: 15)) ?? baseDate
        // 日の出前（前夜が観測夜）と日の出後（当夜が観測夜）。TTL（1 時間）以内の間隔にする。
        let beforeSunrise = calendar.date(
            from: DateComponents(year: 2023, month: 11, day: 15, hour: 5, minute: 50)
        ) ?? baseDate
        let afterSunrise = calendar.date(
            from: DateComponents(year: 2023, month: 11, day: 15, hour: 6, minute: 40)
        ) ?? baseDate

        let weatherService = MockTonightWeatherService()
        weatherService.register(favorite: favorite, dates: [nov14, nov15])
        let calculationService = MockNightCalculationService()
        await calculationService.enqueueUpcomingNights([makeNightSummary(date: nov14, withWindow: true)])

        var now = beforeSunrise
        let provider = FavoriteTonightScoreProvider(
            weatherService: weatherService,
            lightPollutionService: MockLightPollutionService(),
            calculationService: calculationService,
            referenceDateProvider: { now }
        )

        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 1)

        await calculationService.enqueueUpcomingNights([makeNightSummary(date: nov15, withWindow: true)])
        now = afterSunrise
        XCTAssertLessThan(afterSunrise.timeIntervalSince(beforeSunrise), FavoriteTonightScoreProvider.cacheLifetime)
        await provider.refreshIfNeeded(favorites: [favorite])
        XCTAssertEqual(weatherService.fetchCount, 2)
        XCTAssertEqual(provider.score(for: favorite.id)?.computedAt, afterSunrise)
    }

    private func makeFavorite(name: String, latitude: Double, longitude: Double) -> FavoriteLocation {
        FavoriteLocation(
            name: name,
            latitude: latitude,
            longitude: longitude,
            timeZoneIdentifier: "Asia/Tokyo",
            createdAt: baseDate
        )
    }
}

/// 要求された開始日から 1 日ずつ、そのタイムゾーンの 0 時を日付とする夜を返し、要求を記録する。
private actor RecordingTonightCalculationService: NightCalculating {
    struct Request: Equatable {
        let from: Date
        let timeZoneIdentifier: String
    }

    private(set) var requests: [Request] = []

    func calculateNightSummary(date: Date, location: CLLocationCoordinate2D, timeZone: TimeZone) async -> NightSummary {
        makeNightSummary(date: ObservationTimeZone.startOfDay(for: date, timeZone: timeZone), timeZoneIdentifier: timeZone.identifier)
    }

    func calculateUpcomingNights(
        from date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int
    ) async -> [NightSummary] {
        requests.append(Request(from: date, timeZoneIdentifier: timeZone.identifier))
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
private final class MockTonightWeatherService: WeatherProviding {
    @Published var weatherByDate: [String: DayWeatherSummary] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentTemperatureCelsius: Double?

    private(set) var fetchCount = 0
    private var resultByLocationKey: [String: WeatherFetchResult] = [:]

    func registerFailure(favorite: FavoriteLocation) {
        let timeZone = TimeZone(identifier: favorite.timeZoneIdentifier) ?? .current
        let key = locationKey(latitude: favorite.latitude, longitude: favorite.longitude, timeZone: timeZone)
        resultByLocationKey[key] = WeatherFetchResult(
            weatherByDate: [:],
            errorMessage: "weather unavailable",
            lastModifiedDate: nil,
            locationKey: key,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    var weatherByDatePublisher: Published<[String: DayWeatherSummary]>.Publisher { $weatherByDate }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
    var errorMessagePublisher: AnyPublisher<String?, Never> { $errorMessage.eraseToAnyPublisher() }
    var currentTemperaturePublisher: AnyPublisher<Double?, Never> { $currentTemperatureCelsius.eraseToAnyPublisher() }

    func register(favorite: FavoriteLocation, dates: [Date]) {
        let timeZone = TimeZone(identifier: favorite.timeZoneIdentifier) ?? .current
        let key = locationKey(latitude: favorite.latitude, longitude: favorite.longitude, timeZone: timeZone)
        let values = Dictionary(uniqueKeysWithValues: dates.map { date in
            (dateKey(date, timeZone: timeZone), DayWeatherSummary(date: date, nighttimeHours: [
                HourlyWeather(
                    date: date,
                    temperatureCelsius: 15,
                    cloudCoverPercent: 5,
                    precipitationMM: 0,
                    windSpeedKmh: 5,
                    humidityPercent: 40,
                    dewpointCelsius: 2,
                    weatherCode: 0,
                    visibilityMeters: 20_000,
                    windGustsKmh: 10,
                    windSpeedKmh500hpa: nil
                )
            ]))
        })
        resultByLocationKey[key] = WeatherFetchResult(
            weatherByDate: values,
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: key,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    func fetchWeather(latitude: Double, longitude: Double, timeZone: TimeZone) async {}

    func summary(for date: Date) -> DayWeatherSummary? { weatherByDate[dateKey(date, timeZone: .current)] }

    func fetchWeatherSnapshot(latitude: Double, longitude: Double, timeZone: TimeZone) async -> WeatherFetchResult {
        fetchCount += 1
        let key = locationKey(latitude: latitude, longitude: longitude, timeZone: timeZone)
        return resultByLocationKey[key] ?? WeatherFetchResult(
            weatherByDate: [:],
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: key,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    func applyFetchResult(_ result: WeatherFetchResult) {
        weatherByDate = result.weatherByDate
        errorMessage = result.errorMessage
    }

    func summary(for date: Date, from weatherByDate: [String: DayWeatherSummary], timeZone: TimeZone) -> DayWeatherSummary? {
        weatherByDate[dateKey(date, timeZone: timeZone)]
    }

    func isForecastOutOfRange(for date: Date, in weatherByDate: [String: DayWeatherSummary], timeZone: TimeZone) -> Bool { false }

    func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func prepareForLocationChange(latitude: Double, longitude: Double, timeZone: TimeZone) {}

    private func locationKey(latitude: Double, longitude: Double, timeZone: TimeZone) -> String {
        String(format: "%.4f,%.4f|%@", latitude, longitude, timeZone.identifier)
    }
}
