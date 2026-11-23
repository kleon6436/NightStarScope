import Foundation
import Observation
import CoreLocation
import WeatherKit

// WeatherKit.WeatherService と module 名を明示して Apple SDK 側を参照する。

/// WeatherKit から取得した予報を NightScope 用の状態へ変換する。
@MainActor
@Observable
final class WeatherKitService: WeatherProviding {

    // MARK: - Internal location context

    /// 取得対象の地点情報をひとまとめにする。
    private struct LocationContext {
        let latitude: Double
        let longitude: Double
        let timeZone: TimeZone

        var locationKey: String {
            WeatherKitService.locationKey(
                latitude: latitude,
                longitude: longitude,
                timeZone: timeZone
            )
        }
    }

    // MARK: - WeatherProviding observable state

    var weatherByDate: [String: DayWeatherSummary] = [:]
    var isLoading = false
    var errorMessage: String?
    /// 観測地の現在気温（℃）。観測から `currentTemperatureMaxAge` を超えた値は公開しない。
    var currentTemperatureCelsius: Double?

    // MARK: - Cache / state

    @ObservationIgnored private var currentTask: Task<Void, Never>?
    /// 保持する最大場所数
    private let maxCachedLocations = 10
    private let cacheTTLSeconds: TimeInterval = 3600
    @ObservationIgnored private var cacheTimestamps: [String: Date] = [:]
    @ObservationIgnored private var weatherByDateByLocation: [String: [String: DayWeatherSummary]] = [:]
    /// 地点ごとの現在気温。予報キャッシュ（1 時間 TTL）に相乗りするため観測時刻も保持する。
    @ObservationIgnored private var currentByLocation: [String: (celsius: Double, observedAt: Date)] = [:]
    /// 現在気温として表示してよい観測からの経過時間の上限
    private let currentTemperatureMaxAge: TimeInterval = 90 * 60
    /// 現在時刻の取得元（テストで差し替える）
    private let now: () -> Date
    /// 現在気温の失効まで待つ処理（テストで差し替える）
    private let sleep: (TimeInterval) async throws -> Void
    /// 表示中の現在気温を観測から `currentTemperatureMaxAge` 経過時点で消すタスク。
    /// 再取得が起きない間（mac はウィンドウを開いたまま等）も古い値を「現在」と見せないため。
    @ObservationIgnored private var currentTemperatureExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var activeLocationKey: String?
    @ObservationIgnored private var activeTimeZoneIdentifier = TimeZone.current.identifier

    // MARK: - Init

    init(
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    // MARK: - WeatherProviding: fetch

    /// 指定地点の予報を取得し、公開状態へ反映する。
    func fetchWeather(latitude: Double, longitude: Double, timeZone: TimeZone) async {
        let context = LocationContext(latitude: latitude, longitude: longitude, timeZone: timeZone)
        let fallback = cachedWeatherByDate(for: context.locationKey)
        if activeLocationKey != context.locationKey {
            prepareForLocationChange(context)
        }
        currentTask?.cancel()
        isLoading = true
        errorMessage = nil
        currentTask = Task {
            let result = await loadWeather(context: context, fallbackWeatherByDate: fallback)
            guard !Task.isCancelled else { return }
            applyFetchResult(result)
        }
        await currentTask?.value
    }

    /// 取得結果を返すスナップショット版。公開状態（weatherByDate 等）は変更せず、
    /// 新規取得に成功した場合だけメモリ上の地点キャッシュ（1 時間 TTL・最大 10 地点）へ書き込む。
    func fetchWeatherSnapshot(latitude: Double, longitude: Double, timeZone: TimeZone) async -> WeatherFetchResult {
        let context = LocationContext(latitude: latitude, longitude: longitude, timeZone: timeZone)
        let locationKey = context.locationKey
        if let timestamp = cacheTimestamps[locationKey],
           Date().timeIntervalSince(timestamp) < cacheTTLSeconds,
           let cachedData = weatherByDateByLocation[locationKey],
           !cachedData.isEmpty {
            let cachedCurrent = currentByLocation[locationKey]
            return WeatherFetchResult(
                weatherByDate: cachedData,
                errorMessage: nil,
                lastModifiedDate: nil,
                locationKey: locationKey,
                timeZoneIdentifier: timeZone.identifier,
                currentTemperatureCelsius: cachedCurrent?.celsius,
                currentObservedAt: cachedCurrent?.observedAt,
                cachedAt: timestamp
            )
        }
        let result = await loadWeather(
            context: context,
            fallbackWeatherByDate: weatherByDateByLocation[locationKey] ?? [:]
        )
        storeInCache(result)
        return result
    }

    /// 新規取得に成功したスナップショットをメモリ上の地点キャッシュへ書き込む。
    /// 公開中の weatherByDate（選択中の観測地の表示）は変更しない。
    /// キャンセル時の結果は既存キャッシュの使い回しなので、取得時刻（TTL の起点）を更新しないよう書き込まない。
    /// 選択中の観測地は公開中の値と観測時刻を突き合わせて期限切れを判定しているため、
    /// 表示を伴わない書き込みで食い違わないよう applyFetchResult だけが更新する。
    private func storeInCache(_ result: WeatherFetchResult) {
        guard !Task.isCancelled,
              result.locationKey != activeLocationKey,
              result.errorMessage == nil,
              result.cachedAt == nil,
              !result.weatherByDate.isEmpty else { return }
        weatherByDateByLocation[result.locationKey] = result.weatherByDate
        cacheTimestamps[result.locationKey] = Date()
        if let celsius = result.currentTemperatureCelsius {
            currentByLocation[result.locationKey] = (celsius, result.currentObservedAt ?? now())
        }
        evictCacheIfNeeded()
    }

    /// 取得結果をキャッシュと公開状態へ同期する。
    func applyFetchResult(_ result: WeatherFetchResult) {
        activeLocationKey = result.locationKey
        activeTimeZoneIdentifier = result.timeZoneIdentifier
        weatherByDateByLocation[result.locationKey] = result.weatherByDate
        // キャッシュから返した結果では取得時刻を据え置く。更新すると TTL が延び続け、再取得されなくなる。
        if result.errorMessage == nil && !result.weatherByDate.isEmpty {
            cacheTimestamps[result.locationKey] = result.cachedAt ?? Date()
        }
        // 取得失敗時は既存の値を残し、鮮度判定で古いものだけ落とす
        if let celsius = result.currentTemperatureCelsius {
            currentByLocation[result.locationKey] = (celsius, result.currentObservedAt ?? now())
        }
        weatherByDate = result.weatherByDate
        errorMessage = result.errorMessage
        publishCurrentTemperature(for: result.locationKey)
        // WeatherKit は lastModifiedDate を提供しないため省略
        evictCacheIfNeeded()
        isLoading = false
    }

    // MARK: - WeatherProviding: query helpers

    /// 現在の観測地・タイムゾーンで日別要約を引く。
    func summary(for date: Date) -> DayWeatherSummary? {
        summary(for: date, from: weatherByDate, timeZone: activeTimeZone)
    }

    func summary(
        for date: Date,
        from weatherByDate: [String: DayWeatherSummary],
        timeZone: TimeZone
    ) -> DayWeatherSummary? {
        weatherByDate[dateKey(date, timeZone: timeZone)]
    }

    func isForecastOutOfRange(
        for date: Date,
        in weatherByDate: [String: DayWeatherSummary],
        timeZone: TimeZone
    ) -> Bool {
        guard summary(for: date, from: weatherByDate, timeZone: timeZone) == nil,
              let latestForecastDate = weatherByDate.values.map(\.date).max() else {
            return false
        }
        let selectedDay   = ObservationTimeZone.startOfDay(for: date, timeZone: timeZone)
        let latestDay     = ObservationTimeZone.startOfDay(for: latestForecastDate, timeZone: timeZone)
        return selectedDay > latestDay
    }

    func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        Self.makeDateKeyFormatter(timeZone: timeZone).string(from: date)
    }

    /// 観測地切り替え前に既存キャッシュを再利用可能な形へ寄せる。
    func prepareForLocationChange(latitude: Double, longitude: Double, timeZone: TimeZone) {
        currentTask?.cancel()
        prepareForLocationChange(
            LocationContext(latitude: latitude, longitude: longitude, timeZone: timeZone)
        )
    }

    // MARK: - Date key formatter

    /// "yyyy-MM-dd" 形式の DateFormatter を返す（タイムゾーン依存、タイムゾーンごとにキャッシュ済み）。
    private nonisolated static func makeDateKeyFormatter(timeZone: TimeZone) -> DateFormatter {
        FormatterFactory.observationTimeZone(dateFormat: "yyyy-MM-dd", timeZone: timeZone)
    }

    // MARK: - Private helpers

    private var activeTimeZone: TimeZone {
        TimeZone(identifier: activeTimeZoneIdentifier) ?? .current
    }

    private nonisolated static func locationKey(
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone
    ) -> String {
        let lat = (latitude  * 10_000).rounded() / 10_000
        let lon = (longitude * 10_000).rounded() / 10_000
        return String(format: "%.4f,%.4f|%@", lat, lon, timeZone.identifier)
    }

    private func cachedWeatherByDate(for locationKey: String) -> [String: DayWeatherSummary] {
        if let cached = weatherByDateByLocation[locationKey] { return cached }
        if activeLocationKey == locationKey { return weatherByDate }
        return [:]
    }

    private func prepareForLocationChange(_ context: LocationContext) {
        activeLocationKey = context.locationKey
        activeTimeZoneIdentifier = context.timeZone.identifier
        weatherByDate = weatherByDateByLocation[activeLocationKey ?? ""] ?? [:]
        publishCurrentTemperature(for: context.locationKey)
        errorMessage = nil
        isLoading = false
    }

    private func evictCacheIfNeeded() {
        guard weatherByDateByLocation.count > maxCachedLocations else { return }
        // 取得時刻の古い順に追い出す。取得時刻がない（失敗のみ等）場所は最も古い扱いにする。
        let keysToEvict = weatherByDateByLocation.keys
            .filter { $0 != activeLocationKey }
            .sorted { (cacheTimestamps[$0] ?? .distantPast) < (cacheTimestamps[$1] ?? .distantPast) }
        for key in keysToEvict.prefix(weatherByDateByLocation.count - maxCachedLocations) {
            weatherByDateByLocation.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
            currentByLocation.removeValue(forKey: key)
        }
    }

    /// 地点の現在気温を公開し、観測から `currentTemperatureMaxAge` 経過した時点で消す予約を入れ直す。
    private func publishCurrentTemperature(for locationKey: String) {
        currentTemperatureExpiryTask?.cancel()
        currentTemperatureExpiryTask = nil
        currentTemperatureCelsius = freshCurrentTemperature(for: locationKey)
        guard currentTemperatureCelsius != nil, let reading = currentByLocation[locationKey] else { return }
        let remaining = currentTemperatureMaxAge - now().timeIntervalSince(reading.observedAt)
        // sleep を先に取り出し、待機中にサービス自身を保持しない
        let sleep = self.sleep
        currentTemperatureExpiryTask = Task { [weak self] in
            try? await sleep(remaining)
            guard !Task.isCancelled, let self else { return }
            // 待機中に同じ観測値が表示され続けている場合だけ消す
            guard self.activeLocationKey == locationKey,
                  self.currentByLocation[locationKey]?.observedAt == reading.observedAt else { return }
            self.currentTemperatureCelsius = nil
        }
    }

    /// 観測から `currentTemperatureMaxAge` 以内の現在気温だけを返す。
    private func freshCurrentTemperature(for locationKey: String) -> Double? {
        guard let reading = currentByLocation[locationKey],
              now().timeIntervalSince(reading.observedAt) <= currentTemperatureMaxAge else {
            return nil
        }
        return reading.celsius
    }

    // MARK: - WeatherKit fetch

    /// WeatherKit から取得したデータを共有形式へ正規化する。
    private func loadWeather(
        context: LocationContext,
        fallbackWeatherByDate: [String: DayWeatherSummary]
    ) async -> WeatherFetchResult {
        do {
            let clLocation = CLLocation(latitude: context.latitude, longitude: context.longitude)

            // WeatherKit.WeatherService は module 名を明示して参照する
            // .hourly だけでは 24 時間しか取得できないため、開始日と終了日を明示して
            // upcomingNightCount+1 日分（夜間が翌日にまたがる余裕を含む）を要求する
            let requestTime = Date()
            let forecastEndDate = Calendar.current.date(
                byAdding: .day,
                value: ForecastConfiguration.upcomingNightCount + 1,
                to: requestTime
            ) ?? requestTime.addingTimeInterval(Double(ForecastConfiguration.upcomingNightCount + 1) * 24 * 3600)
            // 現在の天気も同じリクエストに同梱し、API 呼び出し回数を増やさない
            let (currentWeather, hourlyForecast) = try await WeatherKit.WeatherService.shared.weather(
                for: clLocation,
                including: .current, .hourly(startDate: requestTime, endDate: forecastEndDate)
            )

            if Task.isCancelled {
                return WeatherFetchResult(
                    weatherByDate: fallbackWeatherByDate,
                    errorMessage: nil,
                    lastModifiedDate: nil,
                    locationKey: context.locationKey,
                    timeZoneIdentifier: context.timeZone.identifier
                )
            }

            let coordinate = CLLocationCoordinate2D(
                latitude: context.latitude,
                longitude: context.longitude
            )
            // WeatherKit の型はメインアクター上で共通の値型へ変換し、夜ごとの束ね（日没探索を含む）だけを
            // メインアクター外で行う。結果の反映（applyFetchResult）は呼び出し元がメインアクターで行う。
            let hours = Self.hourlyWeathers(from: Array(hourlyForecast))
            let timeZone = context.timeZone
            let weatherByDate = await Task.detached(priority: .userInitiated) {
                let signposter = PerformanceSignposts.signposter
                let signpostState = signposter.beginInterval("WeatherNightGrouping", id: signposter.makeSignpostID())
                defer { signposter.endInterval("WeatherNightGrouping", signpostState) }
                return Self.nightlySummaries(from: hours, coordinate: coordinate, timeZone: timeZone)
            }.value

            return WeatherFetchResult(
                weatherByDate: weatherByDate,
                errorMessage: nil,
                lastModifiedDate: nil,
                locationKey: context.locationKey,
                timeZoneIdentifier: context.timeZone.identifier,
                currentTemperatureCelsius: currentWeather.temperature.converted(to: .celsius).value,
                currentObservedAt: currentWeather.date
            )
        } catch {
            let serviceError = WeatherServiceError.networkError(underlying: error)
            return WeatherFetchResult(
                weatherByDate: fallbackWeatherByDate,
                errorMessage: serviceError.localizedDescription,
                lastModifiedDate: nil,
                locationKey: context.locationKey,
                timeZoneIdentifier: context.timeZone.identifier
            )
        }
    }

    // MARK: - Night grouping

    /// WeatherKit HourWeather → 共通 HourlyWeather へ変換する。
    private static func hourlyWeathers(from hourWeathers: [HourWeather]) -> [HourlyWeather] {
        hourWeathers.map { hw in
            HourlyWeather(
                date:                hw.date,
                temperatureCelsius:  hw.temperature.converted(to: .celsius).value,
                cloudCoverPercent:   hw.cloudCover * 100,
                precipitationMM:     hw.precipitationAmount.converted(to: .millimeters).value,
                windSpeedKmh:        hw.wind.speed.converted(to: .kilometersPerHour).value,
                humidityPercent:     hw.humidity * 100,
                dewpointCelsius:     hw.dewPoint.converted(to: .celsius).value,
                weatherCode:         WeatherConditionMapper.wmoCode(for: hw.condition),
                visibilityMeters:    hw.visibility.converted(to: .meters).value,
                windGustsKmh:        hw.wind.gust?.converted(to: .kilometersPerHour).value,
                windSpeedKmh500hpa:  nil   // WeatherKit は 500hPa 風速を非提供
            )
        }
    }

    /// 天気予報を束ねる 1 夜分の区間。
    /// 市民薄明終了後（太陽高度 < -6°）の区間を基本とし、その区間に正時が 1 つも含まれない夜
    /// （高緯度の夏など、太陽が -6° まで沈まない／沈む時間が 1 時間に満たない白夜）は、
    /// 太陽が地平線下（< 0°）の区間で代用する。月・惑星モードでは薄明の空でも観測対象になるため、
    /// 天気が全く得られない夜を作らない。
    /// 根拠: NightSummary の天気網羅判定（weatherCoverageHourStarts）と同じ基準・同じ順序で判定する。
    nonisolated static func weatherNightInterval(
        date: Date,
        coordinate: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> DateInterval? {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let civil = MilkyWayCalculator.civilDarknessInterval(
            date: date,
            location: coordinate,
            timeZone: timeZone
        )
        if let civil, containsHourStart(civil, calendar: calendar) {
            return civil
        }
        if let horizon = MilkyWayCalculator.sunBelowHorizonInterval(
            date: date,
            location: coordinate,
            timeZone: timeZone
        ), containsHourStart(horizon, calendar: calendar) {
            return horizon
        }
        return civil
    }

    /// 区間 [start, end) に正時（時計の hh:00）が含まれるか。予報は正時ごとのため、含まれなければ天気は得られない。
    private nonisolated static func containsHourStart(_ interval: DateInterval, calendar: Calendar) -> Bool {
        guard let hour = calendar.dateInterval(of: .hour, for: interval.start) else { return false }
        let firstHourStart = hour.start == interval.start ? hour.start : hour.end
        return firstHourStart < interval.end
    }

    /// 共通形式の時間別予報を夜間区間ごとに束ねる（テストから直接呼べるよう分離）。
    /// 純粋な計算のみで状態に触れないため、メインアクター外から呼べる。
    nonisolated static func nightlySummaries(
        from hours: [HourlyWeather],
        coordinate: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> [String: DayWeatherSummary] {
        guard let earliest = hours.min(by: { $0.date < $1.date }),
              let latest   = hours.max(by: { $0.date < $1.date }) else {
            return [:]
        }

        let calendar  = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let formatter = Self.makeDateKeyFormatter(timeZone: timeZone)

        let startDay = calendar.date(
            byAdding: .day, value: -1,
            to: calendar.startOfDay(for: earliest.date)
        ) ?? calendar.startOfDay(for: earliest.date)

        let endDay = calendar.date(
            byAdding: .day, value: 1,
            to: calendar.startOfDay(for: latest.date)
        ) ?? calendar.startOfDay(for: latest.date)

        // 各日の夜間インターバルを列挙（市民薄明終了後。白夜は太陽が地平線下の区間で代用。NightSummary と統一）
        var intervals: [(key: String, day: Date, interval: DateInterval)] = []
        var currentDay = startDay
        while currentDay <= endDay {
            if let interval = weatherNightInterval(
                date: currentDay,
                coordinate: coordinate,
                timeZone: timeZone
            ) {
                intervals.append((formatter.string(from: currentDay), currentDay, interval))
            }
            // 0 時が飛ぶ日を経由すると時刻が 1:00 などにずれたまま進むため、毎回その日の始まりへ揃える。
            currentDay = calendar.date(byAdding: .day, value: 1, to: currentDay)
                .map { calendar.startOfDay(for: $0) }
                ?? endDay.addingTimeInterval(1)
        }

        // 各 hour を夜間インターバルへ振り分け
        var grouped: [String: [HourlyWeather]] = [:]
        for hour in hours.sorted(by: { $0.date < $1.date }) {
            if let match = intervals.first(where: { $0.interval.contains(hour.date) }) {
                grouped[match.key, default: []].append(hour)
            }
        }

        // DayWeatherSummary を生成
        var summaries: [String: DayWeatherSummary] = [:]
        // キー文字列を DateFormatter で読み戻すと、0 時が夏時間で飛ぶ日（例: America/Santiago）は
        // nil になりその夜が落ちる。キーを作った日付（その日の始まり）をそのまま使う。
        let dayByKey = Dictionary(intervals.map { ($0.key, $0.day) }, uniquingKeysWith: { first, _ in first })
        for (key, groupedHours) in grouped {
            guard let date = dayByKey[key] else { continue }
            summaries[key] = DayWeatherSummary(
                date: date,
                nighttimeHours: groupedHours.sorted { $0.date < $1.date }
            )
        }
        return summaries
    }
}

// MARK: - WeatherAttributionData

/// WeatherKit の WeatherAttribution から必要な情報を取り出したデータ構造。
/// WeatherKit を import しないビュー層でも安全に利用できる。
struct WeatherAttributionData {
    fileprivate let serviceName: String
    let logoLightURL: URL
    let logoDarkURL: URL
    let legalPageURL: URL
}

// MARK: - WeatherAttributionService

/// WeatherKit が要求する帰属表示情報を取得・キャッシュするサービス。
/// WeatherKit の利用規約により、天気データを表示するすべての箇所で帰属表示が必要。
@MainActor
@Observable
final class WeatherAttributionService {
    private(set) var attributionData: WeatherAttributionData?
    @ObservationIgnored private var isLoading = false

    func loadIfNeeded() async {
        guard attributionData == nil, !isLoading else { return }
        isLoading = true
        if let attr = try? await WeatherKit.WeatherService.shared.attribution {
            attributionData = WeatherAttributionData(
                serviceName: attr.serviceName,
                logoLightURL: attr.combinedMarkLightURL,
                logoDarkURL: attr.combinedMarkDarkURL,
                legalPageURL: attr.legalPageURL
            )
        }
        isLoading = false
    }
}
