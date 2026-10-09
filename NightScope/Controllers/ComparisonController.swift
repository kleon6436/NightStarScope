import Foundation
import CoreLocation

/// 保存済み地点の夜間条件を日単位で比較するコントローラ。
@MainActor
final class ComparisonController: ObservableObject {
    @Published private(set) var matrix: ComparisonMatrix = .empty
    @Published private(set) var isRefreshing = false
    /// 比較に含める日数。
    @Published var dayCount: Int = 7

    private let favoriteStore: any FavoriteLocationStoring
    private let weatherService: any WeatherProviding
    private let lightPollutionService: any LightPollutionProviding
    private let calculationService: any NightCalculating

    /// 比較対象のデータソースを注入する。
    init(
        favoriteStore: any FavoriteLocationStoring,
        weatherService: any WeatherProviding,
        lightPollutionService: any LightPollutionProviding,
        calculationService: any NightCalculating
    ) {
        self.favoriteStore = favoriteStore
        self.weatherService = weatherService
        self.lightPollutionService = lightPollutionService
        self.calculationService = calculationService
    }

    /// 現在の保存地点で比較マトリクスを再構築する。
    func refresh(referenceDate: Date = Date(), locations: [FavoriteLocation]? = nil) async {
        isRefreshing = true
        defer { isRefreshing = false }

        let locations = locations ?? favoriteStore.loadAll()
        let columnTimeZone = TimeZone.current
        let dates = Self.makeDates(referenceDate: referenceDate, dayCount: dayCount, timeZone: columnTimeZone)
        matrix = ComparisonMatrix(
            locations: locations,
            dates: dates,
            cellsByID: Dictionary(uniqueKeysWithValues: locations.flatMap { location in
                dates.map { date in
                    let cell = ComparisonCell(locationID: location.id, date: date, loadState: .loading)
                    return (cell.id, cell)
                }
            }),
            columnTimeZone: columnTimeZone
        )

        let computed = await computeMatrix(referenceDate: referenceDate, locations: locations)
        matrix = computed
    }

    /// 再利用しやすい純粋計算として比較マトリクスを返す。
    func computeMatrix(referenceDate: Date = Date(), locations: [FavoriteLocation]? = nil) async -> ComparisonMatrix {
        let locations = locations ?? favoriteStore.loadAll()
        return await Self.computeMatrix(
            referenceDate: referenceDate,
            locations: locations,
            dayCount: dayCount,
            weatherService: weatherService,
            lightPollutionService: lightPollutionService,
            calculationService: calculationService
        )
    }

    /// 指定地点・指定日のセルを返す。
    func cell(for locationID: UUID, date: Date) -> ComparisonCell? {
        matrix.cellsByID[ComparisonCell.makeID(locationID: locationID, date: date)]
    }

    /// 指定日における最良セルを返す。
    func bestCell(for date: Date) -> ComparisonCell? {
        matrix.locations
            .compactMap { cell(for: $0.id, date: date) }
            .max { ($0.index?.score ?? Int.min) < ($1.index?.score ?? Int.min) }
    }

    /// 列の日付（`timeZone` の各日の 0 時）を作る。列は暦日を表し、地点ごとの夜は年月日で対応付ける。
    private static func makeDates(referenceDate: Date, dayCount: Int, timeZone: TimeZone) -> [Date] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let start = calendar.startOfDay(for: referenceDate)
        return (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start).map { calendar.startOfDay(for: $0) }
        }
    }

    /// 保存済み地点ごとの夜間条件をまとめて評価する。
    static func computeMatrix(
        referenceDate: Date,
        locations: [FavoriteLocation],
        dayCount: Int,
        weatherService: any WeatherProviding,
        lightPollutionService: any LightPollutionProviding,
        calculationService: any NightCalculating
    ) async -> ComparisonMatrix {
        let columnTimeZone = TimeZone.current
        let dates = makeDates(referenceDate: referenceDate, dayCount: dayCount, timeZone: columnTimeZone)
        var cellsByID = Dictionary(uniqueKeysWithValues: locations.flatMap { location in
            dates.map { date in
                let cell = ComparisonCell(locationID: location.id, date: date, loadState: .loading)
                return (cell.id, cell)
            }
        })

        guard !locations.isEmpty else {
            return ComparisonMatrix(locations: [], dates: dates, cellsByID: [:], columnTimeZone: columnTimeZone)
        }
        let indexBuilder = StarGazingIndexBuilder(weatherService: weatherService)
        var weatherFailedLocationIDs: Set<UUID> = []

        for location in locations {
            guard !Task.isCancelled else { break }

            let timeZone = TimeZone(identifier: location.timeZoneIdentifier) ?? .current
            let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            let weatherResult = await weatherService.fetchWeatherSnapshot(
                latitude: location.latitude,
                longitude: location.longitude,
                timeZone: timeZone
            )
            if weatherResult.errorMessage != nil {
                weatherFailedLocationIDs.insert(location.id)
            }
            let bortleClass = try? await lightPollutionService.fetchBortle(
                latitude: location.latitude,
                longitude: location.longitude
            )
            // 列と同じ年月日の夜をこの地点のタイムゾーンで計算する。
            // 列の 0 時（端末のタイムゾーン）から数えると、時差のある地点では夜が 1 日ずれる。
            let firstLocalDay = dates.first.map {
                ObservationTimeZone.preservingCalendarDay($0, from: columnTimeZone, to: timeZone)
            } ?? referenceDate
            let nights = await calculationService.calculateUpcomingNights(
                from: firstLocalDay,
                location: coordinate,
                timeZone: timeZone,
                days: dayCount
            )

            for date in dates {
                let cellID = ComparisonCell.makeID(locationID: location.id, date: date)
                let localDay = ObservationTimeZone.preservingCalendarDay(date, from: columnTimeZone, to: timeZone)
                // 位置ではなく、地点のタイムゾーンでの年月日が列と一致する夜を対応付ける。
                guard let night = nights.first(where: {
                    ObservationTimeZone.isDate($0.date, inSameDayAs: localDay, timeZone: timeZone)
                }) else {
                    cellsByID[cellID] = ComparisonCell(
                        locationID: location.id,
                        date: date,
                        bortleClass: bortleClass,
                        loadState: .failed(L10n.tr("取得失敗"))
                    )
                    continue
                }

                let weather = indexBuilder.weather(for: night, from: weatherResult.weatherByDate)
                let index = indexBuilder.index(
                    for: night,
                    weather: weather,
                    bortleClass: bortleClass,
                    referenceDate: referenceDate
                )
                cellsByID[cellID] = ComparisonCell(
                    locationID: location.id,
                    date: date,
                    nightSummary: night,
                    weather: weather,
                    bortleClass: bortleClass,
                    index: index,
                    loadState: .loaded
                )
            }
        }

        return ComparisonMatrix(
            locations: locations,
            dates: dates,
            cellsByID: cellsByID,
            weatherFailedLocationIDs: weatherFailedLocationIDs,
            columnTimeZone: columnTimeZone
        )
    }
}
