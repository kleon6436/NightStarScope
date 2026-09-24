import Foundation

/// 観測地変更時に並行して取得した計算結果と外部データ。星空指数はまだ含まない。
struct LocationRefreshResults {
    let nightSummary: NightSummary
    let upcomingNights: [NightSummary]
    let weatherResult: WeatherFetchResult
    let lightPollutionResult: LightPollutionService.FetchResult
}

/// 観測地変更時に、当夜・予報の計算と天気・光害の取得を並行して行う。
/// 取得だけを担い、画面状態への反映は AppController が行う。
@MainActor
final class LocationRefreshFetcher {
    private let calculationService: NightCalculating
    private let weatherService: any WeatherProviding
    private let lightPollutionService: LightPollutionService

    init(
        calculationService: NightCalculating,
        weatherService: any WeatherProviding,
        lightPollutionService: LightPollutionService
    ) {
        self.calculationService = calculationService
        self.weatherService = weatherService
        self.lightPollutionService = lightPollutionService
    }

    func fetch(
        for request: AppController.LocationRefreshRequest,
        timeZone: TimeZone
    ) async -> LocationRefreshResults {
        async let summaryTask = calculationService.calculateNightSummary(
            date: request.selectedDate,
            location: request.coordinate,
            timeZone: timeZone
        )
        async let upcomingTask = calculationService.calculateUpcomingNights(
            from: ObservationTimeZone.startOfDay(for: Date(), timeZone: timeZone),
            location: request.coordinate,
            timeZone: timeZone,
            days: ForecastConfiguration.upcomingNightCount
        )
        async let weatherTask = weatherService.fetchWeatherSnapshot(
            latitude: request.coordinate.latitude,
            longitude: request.coordinate.longitude,
            timeZone: timeZone
        )
        async let lightPollutionTask = lightPollutionService.fetchSnapshot(
            latitude: request.coordinate.latitude,
            longitude: request.coordinate.longitude
        )

        return await LocationRefreshResults(
            nightSummary: summaryTask,
            upcomingNights: upcomingTask,
            weatherResult: weatherTask,
            lightPollutionResult: lightPollutionTask
        )
    }
}
