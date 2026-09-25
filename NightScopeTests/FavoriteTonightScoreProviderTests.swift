import XCTest
import Combine
import CoreLocation
@testable import NightScope

@MainActor
final class FavoriteTonightScoreProviderTests: XCTestCase {
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

@MainActor
private final class MockTonightWeatherService: WeatherProviding {
    @Published var weatherByDate: [String: DayWeatherSummary] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var fetchCount = 0
    private var resultByLocationKey: [String: WeatherFetchResult] = [:]

    var weatherByDatePublisher: Published<[String: DayWeatherSummary]>.Publisher { $weatherByDate }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
    var errorMessagePublisher: AnyPublisher<String?, Never> { $errorMessage.eraseToAnyPublisher() }

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
