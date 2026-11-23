import Foundation
import CoreLocation
import Observation

/// 保存済み地点の夜間条件を日単位で比較するコントローラ。
@MainActor
@Observable
final class ComparisonController {
    private(set) var matrix: ComparisonMatrix = .empty
    private(set) var isRefreshing = false
    /// 比較に含める日数。
    var dayCount: Int = 7

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
        // 計算結果の行列と同じ列（各地点の観測日にそろえた暦日）にし、読み込み中に列がずれないようにする
        let dates = Self.makeDates(
            referenceDate: referenceDate,
            dayCount: dayCount,
            timeZone: columnTimeZone,
            locations: locations
        )
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
    /// 先頭列は各地点の「今夜」（観測日）のうち最も早い暦日にそろえ、深夜〜明け方でも進行中の夜を含める。
    static func makeDates(
        referenceDate: Date,
        dayCount: Int,
        timeZone: TimeZone,
        locations: [FavoriteLocation] = []
    ) -> [Date] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let start = firstColumnDate(referenceDate: referenceDate, timeZone: timeZone, locations: locations)
        return (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start).map { calendar.startOfDay(for: $0) }
        }
    }

    /// 各地点の観測日（アプリ全体の「今日」）を列のタイムゾーンの暦日に写し、最も早いものを返す。
    private static func firstColumnDate(
        referenceDate: Date,
        timeZone: TimeZone,
        locations: [FavoriteLocation]
    ) -> Date {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let calendarToday = calendar.startOfDay(for: referenceDate)
        let observationDays = locations.map { location -> Date in
            let locationTimeZone = TimeZone(identifier: location.timeZoneIdentifier) ?? timeZone
            let observationDate = StarMapDateLogic.currentObservationDate(
                for: referenceDate,
                location: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                timeZone: locationTimeZone
            )
            return ObservationTimeZone.preservingCalendarDay(observationDate, from: locationTimeZone, to: timeZone)
        }
        return observationDays.min() ?? calendarToday
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
        let dates = makeDates(
            referenceDate: referenceDate,
            dayCount: dayCount,
            timeZone: columnTimeZone,
            locations: locations
        )
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
        let fetches = await fetchLocationInputs(
            locations: locations,
            firstColumnDate: dates.first,
            columnTimeZone: columnTimeZone,
            referenceDate: referenceDate,
            dayCount: dayCount,
            weatherService: weatherService,
            lightPollutionService: lightPollutionService,
            calculationService: calculationService
        )

        // キャンセル等で取得できなかった地点のセルは読み込み中のまま残す（従来の逐次処理での break と同じ）。
        // キャンセル後に完了した地点はキャッシュの使い回しや空の結果を返すため、天気なしの読み込み済みセルにしない。
        let isCancelled = Task.isCancelled
        for (location, fetch) in zip(locations, fetches) {
            guard !isCancelled, let fetch else { continue }
            let timeZone = fetch.timeZone
            let weatherResult = fetch.weatherResult
            let bortleClass = fetch.bortleClass
            let nights = fetch.nights
            if weatherResult.errorMessage != nil {
                weatherFailedLocationIDs.insert(location.id)
            }

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
    /// 1 地点分の取得結果。
    private struct LocationInputs: Sendable {
        let timeZone: TimeZone
        let weatherResult: WeatherFetchResult
        let bortleClass: Double?
        let nights: [NightSummary]
    }

    /// 同時に取得する地点数の上限。WeatherKit への同時リクエストを抑えつつ逐次待ちを減らす。
    private static let maxConcurrentLocationFetches = 3

    /// 地点ごとの天気・光害・夜間計算を、最大 `maxConcurrentLocationFetches` 地点ずつ並行して取得する。
    /// 戻り値は `locations` と同じ順序で、キャンセルにより取得しなかった地点は nil。
    private static func fetchLocationInputs(
        locations: [FavoriteLocation],
        firstColumnDate: Date?,
        columnTimeZone: TimeZone,
        referenceDate: Date,
        dayCount: Int,
        weatherService: any WeatherProviding,
        lightPollutionService: any LightPollutionProviding,
        calculationService: any NightCalculating
    ) async -> [LocationInputs?] {
        await withTaskGroup(of: (Int, LocationInputs).self) { group in
            var results = [LocationInputs?](repeating: nil, count: locations.count)
            var nextIndex = 0
            var runningCount = 0
            while true {
                while runningCount < maxConcurrentLocationFetches,
                      nextIndex < locations.count,
                      !Task.isCancelled {
                    let index = nextIndex
                    let location = locations[index]
                    nextIndex += 1
                    runningCount += 1
                    group.addTask {
                        let inputs = await fetchInputs(
                            for: location,
                            firstColumnDate: firstColumnDate,
                            columnTimeZone: columnTimeZone,
                            referenceDate: referenceDate,
                            dayCount: dayCount,
                            weatherService: weatherService,
                            lightPollutionService: lightPollutionService,
                            calculationService: calculationService
                        )
                        return (index, inputs)
                    }
                }
                guard let (index, inputs) = await group.next() else { break }
                runningCount -= 1
                results[index] = inputs
            }
            return results
        }
    }

    /// 1 地点分の天気・光害・夜間計算を並行して取得する。
    private static func fetchInputs(
        for location: FavoriteLocation,
        firstColumnDate: Date?,
        columnTimeZone: TimeZone,
        referenceDate: Date,
        dayCount: Int,
        weatherService: any WeatherProviding,
        lightPollutionService: any LightPollutionProviding,
        calculationService: any NightCalculating
    ) async -> LocationInputs {
        let timeZone = TimeZone(identifier: location.timeZoneIdentifier) ?? .current
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        // 列と同じ年月日の夜をこの地点のタイムゾーンで計算する。
        // 列の 0 時（端末のタイムゾーン）から数えると、時差のある地点では夜が 1 日ずれる。
        let firstLocalDay = firstColumnDate.map {
            ObservationTimeZone.preservingCalendarDay($0, from: columnTimeZone, to: timeZone)
        } ?? referenceDate

        async let weatherResult = weatherService.fetchWeatherSnapshot(
            latitude: location.latitude,
            longitude: location.longitude,
            timeZone: timeZone
        )
        async let bortleClass = try? lightPollutionService.fetchBortle(
            latitude: location.latitude,
            longitude: location.longitude
        )
        async let nights = calculationService.calculateUpcomingNights(
            from: firstLocalDay,
            location: coordinate,
            timeZone: timeZone,
            days: dayCount
        )
        return await LocationInputs(
            timeZone: timeZone,
            weatherResult: weatherResult,
            bortleClass: bortleClass,
            nights: nights
        )
    }
}
