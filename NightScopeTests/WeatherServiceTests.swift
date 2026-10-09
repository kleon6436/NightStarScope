import XCTest
import CoreLocation
import WeatherKit
@testable import NightScope

@MainActor
final class WeatherServiceTests: XCTestCase {

    private let tokyoTimeZone = TestTimeZones.tokyo
    private let tokyoLocation = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)

    // MARK: - WeatherKitService 初期状態

    func test_weatherKitService_initialState() {
        let service = WeatherKitService()
        XCTAssertTrue(service.weatherByDate.isEmpty)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.errorMessage)
    }

    // MARK: - isForecastOutOfRange

    func test_weatherKitService_isForecastOutOfRange_returnsFalseWhenKeyExists() {
        let service = WeatherKitService()
        let tz = tokyoTimeZone
        let date = makeDateInTokyo(year: 2024, month: 6, day: 15)
        let key = service.dateKey(date, timeZone: tz)
        let summary = DayWeatherSummary(date: date, nighttimeHours: [])
        let weatherByDate = [key: summary]

        XCTAssertFalse(service.isForecastOutOfRange(for: date, in: weatherByDate, timeZone: tz))
    }

    func test_weatherKitService_isForecastOutOfRange_returnsTrueAfterLatestDay() {
        let service = WeatherKitService()
        let tz = tokyoTimeZone
        // 最新予報: 6/15
        let latestDate = makeDateInTokyo(year: 2024, month: 6, day: 15)
        let latestKey  = service.dateKey(latestDate, timeZone: tz)
        let weatherByDate = [latestKey: DayWeatherSummary(date: latestDate, nighttimeHours: [])]

        // 6/16 は範囲外
        let futureDate = makeDateInTokyo(year: 2024, month: 6, day: 16)
        XCTAssertTrue(service.isForecastOutOfRange(for: futureDate, in: weatherByDate, timeZone: tz))
    }

    func test_weatherKitService_isForecastOutOfRange_returnsFalseForEmptyWeather() {
        let service = WeatherKitService()
        let date = makeDateInTokyo(year: 2024, month: 6, day: 15)
        // 空の weatherByDate では latestForecastDate が取れず false
        XCTAssertFalse(service.isForecastOutOfRange(for: date, in: [:], timeZone: tokyoTimeZone))
    }

    // MARK: - locationKey キャッシュ分離

    func test_weatherKitService_locationKey_cacheIsolation() {
        let service = WeatherKitService()
        let tz = tokyoTimeZone

        let tokyoDate = makeDateInTokyo(year: 2024, month: 6, day: 15)
        let osakaDate = makeDateInTokyo(year: 2024, month: 6, day: 15)

        // 東京: 35.6762, 139.6503
        let tokyoKey = service.dateKey(tokyoDate, timeZone: tz)
        let tokyoSummary = DayWeatherSummary(date: tokyoDate, nighttimeHours: [])
        let tokyoResult = WeatherFetchResult(
            weatherByDate: [tokyoKey: tokyoSummary],
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: "35.6762,139.6503|Asia/Tokyo",
            timeZoneIdentifier: tz.identifier
        )
        service.applyFetchResult(tokyoResult)
        XCTAssertFalse(service.weatherByDate.isEmpty, "東京の天気が反映されるべき")

        // 大阪: 34.6937, 135.5022
        let osakaKey = service.dateKey(osakaDate, timeZone: tz)
        let osakaSummary = DayWeatherSummary(date: osakaDate, nighttimeHours: [])
        let osakaResult = WeatherFetchResult(
            weatherByDate: [osakaKey: osakaSummary],
            errorMessage: nil,
            lastModifiedDate: nil,
            locationKey: "34.6937,135.5022|Asia/Tokyo",
            timeZoneIdentifier: tz.identifier
        )
        service.applyFetchResult(osakaResult)

        // 大阪に切り替わり、大阪のキャッシュが表示される
        XCTAssertFalse(service.weatherByDate.isEmpty, "大阪の天気が反映されるべき")
        XCTAssertEqual(service.weatherByDate[osakaKey]?.date, osakaDate)
    }

    // MARK: - dateKey フォーマット

    func test_weatherKitService_dateKey_format() {
        let service = WeatherKitService()
        let tz = TestTimeZones.tokyo
        var comps = DateComponents()
        comps.year = 2024; comps.month = 6; comps.day = 15; comps.hour = 12
        comps.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(service.dateKey(date, timeZone: tz), "2024-06-15")
    }

    func test_weatherKitService_dateKey_singleDigitMonthAndDay_zeroPadded() {
        let service = WeatherKitService()
        let tz = TestTimeZones.tokyo
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 5; comps.hour = 12
        comps.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(service.dateKey(date, timeZone: tz), "2024-03-05")
    }

    // MARK: - WeatherConditionMapper

    func test_weatherConditionMapper_allCases_returnValidWMOCode() {
        let allConditions: [WeatherCondition] = [
            .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .cloudy,
            .foggy, .drizzle, .freezingDrizzle, .rain, .heavyRain,
            .sunShowers, .isolatedThunderstorms, .scatteredThunderstorms,
            .thunderstorms, .strongStorms, .hail, .blizzard, .wintryMix,
            .flurries, .snow, .sunFlurries, .blowingSnow, .heavySnow,
            .sleet, .freezingRain, .tropicalStorm, .hurricane,
            .breezy, .windy, .frigid, .hot, .haze, .smoky, .blowingDust
        ]
        for condition in allConditions {
            let code = WeatherConditionMapper.wmoCode(for: condition)
            XCTAssertTrue((0...99).contains(code),
                          "\(condition) → \(code) は有効な WMO コード範囲外です")
        }
    }

    func test_weatherConditionMapper_clearSky_returnsZero() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .clear), 0)
    }

    func test_weatherConditionMapper_thunderstorm_returns95() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .thunderstorms), 95)
    }

    func test_weatherConditionMapper_cloudy_returns3() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .cloudy), 3)
    }

    func test_weatherConditionMapper_heavySnow_returns75() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .heavySnow), 75)
    }

    func test_weatherConditionMapper_foggy_returns45() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .foggy), 45)
    }

    func test_weatherConditionMapper_blizzard_mapsToHeavySnow() {
        let code = WeatherConditionMapper.wmoCode(for: .blizzard)
        XCTAssertEqual(code, 75)
        XCTAssertGreaterThanOrEqual(code, WeatherConditionMapper.wmoCode(for: .snow), "吹雪は通常の雪より深刻に扱う")
    }

    func test_weatherCode68_sleetAndFreezingRain_hasLabelIconAndColor() {
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .sleet), 68)
        XCTAssertEqual(WeatherConditionMapper.wmoCode(for: .freezingRain), 68)

        let summary = DayWeatherSummary(date: Date(), nighttimeHours: [makeHourlyWeather(code: 68)])
        XCTAssertEqual(summary.weatherLabel, L10n.tr("みぞれ・着氷性の雨"))
        XCTAssertNotEqual(summary.weatherLabel, L10n.tr("不明"))
        XCTAssertEqual(summary.weatherIconName, "cloud.sleet.fill")
        XCTAssertNotEqual(WeatherPresentation.color(forWeatherCode: 68), .secondary)
    }

    // MARK: - キャッシュの鮮度

    func test_fetchWeatherSnapshot_cacheHit_doesNotRenewCacheTimestamp() async {
        let service = WeatherKitService()
        let tz = tokyoTimeZone
        let locationKey = String(format: "%.4f,%.4f|%@", 35.6762, 139.6503, tz.identifier)
        let date = makeDateInTokyo(year: 2024, month: 6, day: 15)
        service.applyFetchResult(
            WeatherFetchResult(
                weatherByDate: [service.dateKey(date, timeZone: tz): DayWeatherSummary(date: date, nighttimeHours: [])],
                errorMessage: nil,
                lastModifiedDate: nil,
                locationKey: locationKey,
                timeZoneIdentifier: tz.identifier
            )
        )

        let first = await service.fetchWeatherSnapshot(latitude: 35.6762, longitude: 139.6503, timeZone: tz)
        guard let firstCachedAt = first.cachedAt else {
            XCTFail("キャッシュから返した結果には元の取得時刻が入るはず")
            return
        }
        // キャッシュ由来の結果を反映しても、取得時刻（TTL の起点）は延ばさない
        service.applyFetchResult(first)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await service.fetchWeatherSnapshot(latitude: 35.6762, longitude: 139.6503, timeZone: tz)

        XCTAssertEqual(second.cachedAt, firstCachedAt)
    }

    // MARK: - 夜間グルーピング

    /// 0 時が夏時間で飛ぶ日（America/Santiago 2026-09-06）の夜も落とさない。
    func test_nightlySummaries_keepsNightWhoseMidnightIsSkippedByDST() {
        let santiago = TimeZone(identifier: "America/Santiago")!
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: santiago)
        let coordinate = CLLocationCoordinate2D(latitude: -33.45, longitude: -70.66)
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!
        let hours = (0..<72).map { offset in
            makeHourlyWeather(code: 0, date: start.addingTimeInterval(Double(offset) * 3600))
        }

        let summaries = WeatherKitService.nightlySummaries(from: hours, coordinate: coordinate, timeZone: santiago)

        let skippedDay = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!)
        let key = WeatherKitService().dateKey(skippedDay, timeZone: santiago)
        XCTAssertEqual(key, "2026-09-06")
        guard let summary = summaries[key] else {
            XCTFail("0 時が飛ぶ日の夜が落ちている: \(summaries.keys.sorted())")
            return
        }
        XCTAssertEqual(summary.date, skippedDay)
        // 後続の日も 0 時（その日の始まり）に揃っている
        if let next = summaries["2026-09-07"] {
            XCTAssertEqual(next.date, calendar.startOfDay(for: next.date))
        }
    }

    /// 太陽が -6° まで沈まない夜（トロンハイム 63.4°N の夏至）は、太陽が地平線下の時間帯で天気を束ねる。
    func test_nightlySummaries_whiteNightFallsBackToHoursWithSunBelowHorizon() throws {
        let oslo = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let coordinate = CLLocationCoordinate2D(latitude: 63.4305, longitude: 10.3951)
        let summaries = nightlySummaries(around: (2026, 6, 21), coordinate: coordinate, timeZone: oslo)

        let night = try XCTUnwrap(summaries["2026-06-21"], "\(summaries.keys.sorted())")
        XCTAssertNil(MilkyWayCalculator.civilDarknessInterval(date: night.date, location: coordinate, timeZone: oslo))
        let hours = night.nighttimeHours.map { ObservationTimeZone.gregorianCalendar(timeZone: oslo).component(.hour, from: $0.date) }
        XCTAssertEqual(hours, [0, 1, 2, 3])
        for hour in night.nighttimeHours {
            XCTAssertLessThan(sunAltitude(at: hour.date, coordinate: coordinate), 0, "\(hour.date)")
        }

        // NightSummary 側も同じ基準で「天気あり」と判定する
        let nightSummary = MilkyWayCalculator.calculateNightSummary(date: night.date, location: coordinate, timeZone: oslo)
        XCTAssertEqual(nightSummary.totalDarkHours, 0)
        XCTAssertTrue(nightSummary.hasReliableWeatherData(nighttimeHours: night.nighttimeHours))
    }

    /// -6° 未満の時間が 1 時間に満たず正時を含まない夜（60.5°N の夏至）も、地平線下の時間帯で天気を束ねる。
    func test_nightlySummaries_shortCivilNightWithoutHourFallsBackToHorizonHours() throws {
        let helsinki = try XCTUnwrap(TimeZone(identifier: "Europe/Helsinki"))
        let coordinate = CLLocationCoordinate2D(latitude: 60.5, longitude: 25.0)
        let summaries = nightlySummaries(around: (2026, 6, 21), coordinate: coordinate, timeZone: helsinki)

        let night = try XCTUnwrap(summaries["2026-06-21"], "\(summaries.keys.sorted())")
        // 市民薄明後の区間（約 01:07〜01:38）自体はあるが正時を含まない
        XCTAssertNotNil(MilkyWayCalculator.civilDarknessInterval(date: night.date, location: coordinate, timeZone: helsinki))
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: helsinki)
        XCTAssertEqual(night.nighttimeHours.map { calendar.component(.hour, from: $0.date) }, [23, 0, 1, 2, 3, 4])

        let nightSummary = MilkyWayCalculator.calculateNightSummary(date: night.date, location: coordinate, timeZone: helsinki)
        XCTAssertTrue(nightSummary.hasReliableWeatherData(nighttimeHours: night.nighttimeHours))
    }

    /// 通常の夜（東京）は従来どおり市民薄明後（太陽高度 < -6°）の正時だけを束ねる。
    func test_nightlySummaries_regularNightUsesCivilDarknessOnly() throws {
        let summaries = nightlySummaries(around: (2026, 6, 21), coordinate: tokyoLocation, timeZone: tokyoTimeZone)
        let night = try XCTUnwrap(summaries["2026-06-21"])
        XCTAssertFalse(night.nighttimeHours.isEmpty)
        for hour in night.nighttimeHours {
            XCTAssertLessThan(sunAltitude(at: hour.date, coordinate: tokyoLocation), -6, "\(hour.date)")
        }
    }

    /// 指定日の前日 12:00 から 72 時間分の正時予報を束ねる。
    private func nightlySummaries(
        around day: (year: Int, month: Int, day: Int),
        coordinate: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) -> [String: DayWeatherSummary] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day - 1, hour: 12))!
        let hours = (0..<72).map { offset in
            makeHourlyWeather(code: 0, date: start.addingTimeInterval(Double(offset) * 3600))
        }
        return WeatherKitService.nightlySummaries(from: hours, coordinate: coordinate, timeZone: timeZone)
    }

    private func sunAltitude(at date: Date, coordinate: CLLocationCoordinate2D) -> Double {
        let jd = MilkyWayCalculator.julianDate(from: date)
        let lst = MilkyWayCalculator.localSiderealTime(jd: jd, longitude: coordinate.longitude)
        let sun = MilkyWayCalculator.sunRaDec(jd: jd)
        return MilkyWayCalculator.altitude(ra: sun.ra, dec: sun.dec, latitude: coordinate.latitude, lst: lst)
    }

    private func makeHourlyWeather(code: Int, date: Date = Date()) -> HourlyWeather {
        HourlyWeather(
            date: date,
            temperatureCelsius: 10,
            cloudCoverPercent: 0,
            precipitationMM: 0,
            windSpeedKmh: 0,
            humidityPercent: 50,
            dewpointCelsius: 0,
            weatherCode: code,
            visibilityMeters: nil,
            windGustsKmh: nil,
            windSpeedKmh500hpa: nil
        )
    }

    // MARK: - DayWeatherSummary.dewRiskLevel

    private func makeHourlyWeather(temperature: Double, dewpoint: Double) -> HourlyWeather {
        HourlyWeather(
            date: Date(),
            temperatureCelsius: temperature,
            cloudCoverPercent: 0,
            precipitationMM: 0,
            windSpeedKmh: 0,
            humidityPercent: 50,
            dewpointCelsius: dewpoint,
            weatherCode: 0,
            visibilityMeters: nil,
            windGustsKmh: nil,
            windSpeedKmh500hpa: nil
        )
    }

    /// nighttimeHours が空のとき nil を返す
    func test_dewRiskLevel_emptyHours_returnsNil() {
        let summary = DayWeatherSummary(date: Date(), nighttimeHours: [])
        XCTAssertNil(summary.dewRiskLevel)
    }

    /// 平均 spread が 1.5°（< 2.0）のとき .high を返す
    func test_dewRiskLevel_spread1_5_returnsHigh() {
        // spread = 20.0 - 18.5 = 1.5
        let hours = [makeHourlyWeather(temperature: 20.0, dewpoint: 18.5)]
        let summary = DayWeatherSummary(date: Date(), nighttimeHours: hours)
        XCTAssertEqual(summary.dewRiskLevel, .high)
    }

    /// 平均 spread が 3.0°（2.0 ≤ spread < 5.0）のとき .medium を返す
    func test_dewRiskLevel_spread3_0_returnsMedium() {
        // spread = 23.0 - 20.0 = 3.0
        let hours = [makeHourlyWeather(temperature: 23.0, dewpoint: 20.0)]
        let summary = DayWeatherSummary(date: Date(), nighttimeHours: hours)
        XCTAssertEqual(summary.dewRiskLevel, .medium)
    }

    /// 平均 spread が 6.0°（≥ 5.0）のとき .low を返す
    func test_dewRiskLevel_spread6_0_returnsLow() {
        // spread = 26.0 - 20.0 = 6.0
        let hours = [makeHourlyWeather(temperature: 26.0, dewpoint: 20.0)]
        let summary = DayWeatherSummary(date: Date(), nighttimeHours: hours)
        XCTAssertEqual(summary.dewRiskLevel, .low)
    }

    /// 複数時間の平均 spread が閾値境界付近で正しく分類される
    func test_dewRiskLevel_averageSpread_usedCorrectly() {
        // h1: spread = 1.0, h2: spread = 3.0 → avg = 2.0 → .medium (spread < 5.0, ≥ 2.0)
        let h1 = makeHourlyWeather(temperature: 11.0, dewpoint: 10.0)  // spread = 1.0
        let h2 = makeHourlyWeather(temperature: 13.0, dewpoint: 10.0)  // spread = 3.0
        let summary = DayWeatherSummary(date: Date(), nighttimeHours: [h1, h2])
        XCTAssertEqual(summary.avgDewpointSpread, 2.0, accuracy: 0.001)
        XCTAssertEqual(summary.dewRiskLevel, .medium)
    }

    // MARK: - Helpers

    private func makeDateInTokyo(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.timeZone = tokyoTimeZone
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
