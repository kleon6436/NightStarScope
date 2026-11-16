import XCTest
import CoreLocation
@testable import NightScope

/// 性能改善前後で比較するための計測用ベースライン。
/// 値の正しさは他のテストで検証するため、ここでは計測対象の処理だけを繰り返す。
final class PerformanceBaselineTests: XCTestCase {
    private let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
    private let tokyoTimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    private let highLatitude = CLLocationCoordinate2D(latitude: 65.0, longitude: 25.5)
    private let highLatitudeTimeZone = TimeZone(identifier: "Europe/Helsinki") ?? .current

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, timeZone: TimeZone) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func consecutiveDays(from start: Date, count: Int, timeZone: TimeZone) -> [Date] {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: - Darkness intervals

    func test_perf_darknessIntervals_tokyo_30days() {
        let days = consecutiveDays(
            from: makeDate(year: 2026, month: 3, day: 1, timeZone: tokyoTimeZone),
            count: 30,
            timeZone: tokyoTimeZone
        )
        measure(metrics: [XCTClockMetric()], options: options) {
            for day in days {
                _ = MilkyWayCalculator.sunsetSunriseInterval(date: day, location: tokyo, timeZone: tokyoTimeZone)
                _ = MilkyWayCalculator.civilDarknessInterval(date: day, location: tokyo, timeZone: tokyoTimeZone)
            }
        }
    }

    func test_perf_darknessIntervals_65N_June_30days() {
        let days = consecutiveDays(
            from: makeDate(year: 2026, month: 6, day: 1, timeZone: highLatitudeTimeZone),
            count: 30,
            timeZone: highLatitudeTimeZone
        )
        measure(metrics: [XCTClockMetric()], options: options) {
            for day in days {
                _ = MilkyWayCalculator.sunsetSunriseInterval(
                    date: day,
                    location: highLatitude,
                    timeZone: highLatitudeTimeZone
                )
                _ = MilkyWayCalculator.civilDarknessInterval(
                    date: day,
                    location: highLatitude,
                    timeZone: highLatitudeTimeZone
                )
            }
        }
    }

    /// メモ化を毎回破棄して、探索そのものの所要時間を測る（Phase 0 の数値と比較する用）。
    func test_perf_darknessIntervals_tokyo_30days_uncached() {
        let days = consecutiveDays(
            from: makeDate(year: 2026, month: 3, day: 1, timeZone: tokyoTimeZone),
            count: 30,
            timeZone: tokyoTimeZone
        )
        measure(metrics: [XCTClockMetric()], options: options) {
            MilkyWayCalculator.clearDarknessIntervalCache()
            for day in days {
                _ = MilkyWayCalculator.sunsetSunriseInterval(date: day, location: tokyo, timeZone: tokyoTimeZone)
                _ = MilkyWayCalculator.civilDarknessInterval(date: day, location: tokyo, timeZone: tokyoTimeZone)
            }
        }
    }

    func test_perf_darknessIntervals_65N_June_30days_uncached() {
        let days = consecutiveDays(
            from: makeDate(year: 2026, month: 6, day: 1, timeZone: highLatitudeTimeZone),
            count: 30,
            timeZone: highLatitudeTimeZone
        )
        measure(metrics: [XCTClockMetric()], options: options) {
            MilkyWayCalculator.clearDarknessIntervalCache()
            for day in days {
                _ = MilkyWayCalculator.sunsetSunriseInterval(
                    date: day,
                    location: highLatitude,
                    timeZone: highLatitudeTimeZone
                )
                _ = MilkyWayCalculator.civilDarknessInterval(
                    date: day,
                    location: highLatitude,
                    timeZone: highLatitudeTimeZone
                )
            }
        }
    }

    // MARK: - Upcoming nights

    func test_perf_calculateUpcomingNights_tokyo_9nights() {
        let start = makeDate(year: 2026, month: 3, day: 1, timeZone: tokyoTimeZone)
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = MilkyWayCalculator.calculateUpcomingNights(
                from: start,
                location: tokyo,
                timeZone: tokyoTimeZone,
                days: 9
            )
        }
    }

    // MARK: - Date formatting

    func test_perf_dateFormatters_1000calls() {
        let base = makeDate(year: 2026, month: 3, day: 1, hour: 21, timeZone: tokyoTimeZone)
        measure(metrics: [XCTClockMetric()], options: options) {
            for index in 0..<1000 {
                let date = base.addingTimeInterval(Double(index) * 600)
                _ = DateFormatters.nightTimeString(from: date, timeZone: tokyoTimeZone)
                _ = DateFormatters.monthDayString(from: date, timeZone: tokyoTimeZone)
                _ = DateFormatters.fullDateString(from: date, timeZone: tokyoTimeZone)
                _ = DateFormatters.yearMonthDayWeekdayString(from: date, timeZone: tokyoTimeZone)
            }
        }
    }

    @MainActor
    func test_perf_weatherDateKey_1000calls() {
        let service = WeatherKitService()
        let base = makeDate(year: 2026, month: 3, day: 1, timeZone: tokyoTimeZone)
        measure(metrics: [XCTClockMetric()], options: options) {
            for index in 0..<1000 {
                _ = service.dateKey(base.addingTimeInterval(Double(index) * 3600), timeZone: tokyoTimeZone)
            }
        }
    }

    // MARK: - Weather night grouping

    func test_perf_weatherNightlySummaries_240hours() {
        let start = makeDate(year: 2026, month: 3, day: 1, timeZone: tokyoTimeZone)
        let hours = (0..<240).map { offset in
            HourlyWeather(
                date: start.addingTimeInterval(Double(offset) * 3600),
                temperatureCelsius: 10,
                cloudCoverPercent: Double(offset % 100),
                precipitationMM: 0,
                windSpeedKmh: 5,
                humidityPercent: 60,
                dewpointCelsius: 2,
                weatherCode: 0,
                visibilityMeters: 20_000,
                windGustsKmh: 10,
                windSpeedKmh500hpa: nil
            )
        }
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = WeatherKitService.nightlySummaries(from: hours, coordinate: tokyo, timeZone: tokyoTimeZone)
        }
    }

    // MARK: - Star map snapshot

    func test_perf_starMapCompute_fullCatalog() {
        // 星カタログのデコードは初回だけなので計測外で済ませる。
        _ = StarCatalog.stars
        let julianDate = 2_461_041.5
        let localSiderealTime = MilkyWayCalculator.localSiderealTime(jd: julianDate, longitude: tokyo.longitude)
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = StarMapComputation.compute(
                latitude: tokyo.latitude,
                longitude: tokyo.longitude,
                julianDate: julianDate,
                localSiderealTime: localSiderealTime,
                activeMeteorShowers: [],
                starDisplayDensity: .maximum
            )
        }
    }

    /// 時刻スライダー操作 1 回ぶんの更新（60 分を 1 分刻みでスナップショットを作り直す）。
    /// 恒星は回転行列の作り直しだけで、太陽・月・惑星・天の川・星座線など時刻で動くものは従来どおり計算する。
    func test_perf_starMapTimeStepUpdate_60steps() {
        _ = StarCatalog.stars
        _ = StarMapComputation.catalogGeometry
        let startJulianDate = 2_461_041.5
        measure(metrics: [XCTClockMetric()], options: options) {
            for step in 0..<60 {
                let julianDate = startJulianDate + Double(step) / 1440
                _ = StarMapComputation.compute(
                    latitude: tokyo.latitude,
                    longitude: tokyo.longitude,
                    julianDate: julianDate,
                    localSiderealTime: MilkyWayCalculator.localSiderealTime(
                        jd: julianDate,
                        longitude: tokyo.longitude
                    ),
                    activeMeteorShowers: [],
                    starDisplayDensity: .maximum
                )
            }
        }
    }

    /// 1 フレームぶんの恒星投影（最大密度の全星、地平線カット + 赤道座標からの直接投影）。
    func test_perf_starMapFrameProjection_fullCatalog() {
        let size = CGSize(width: 900, height: 600)
        let lst = MilkyWayCalculator.localSiderealTime(jd: 2_461_041.5, longitude: tokyo.longitude)
        let starField = StarMapComputation.compute(
            latitude: tokyo.latitude,
            longitude: tokyo.longitude,
            julianDate: 2_461_041.5,
            localSiderealTime: lst,
            activeMeteorShowers: [],
            starDisplayDensity: .maximum
        ).starField
        let basis = GnomonicProjectionMath.cameraBasis(centerAlt: 30, centerAz: 160, roll: 0)
        let scale = GnomonicProjectionMath.projectionScale(size: size, horizontalFOV: 90)
        measure(metrics: [XCTClockMetric()], options: options) {
            let projector = GnomonicProjectionMath.EquatorialProjector(
                cx: size.width / 2, cy: size.height / 2, scale: scale,
                forward: basis.forward, right: basis.right, up: basis.up, rotation: starField.rotation
            )
            var visible = 0
            for indices in [starField.brightCatalogIndices, starField.faintCatalogIndices] {
                starField.forEachProjectedStar(in: indices, projector: projector) { _, _, _ in
                    visible += 1
                }
            }
            XCTAssertGreaterThan(visible, 0)
        }
    }

    // MARK: - Star catalog decode

    /// stars_fill.json (25,650 行) のデコード・Star 変換・名前付き星との重複除外。
    /// `StarCatalog.stars` の静的キャッシュを通さず、同じ処理を毎回やり直す。
    func test_perf_starCatalogDecode() throws {
        guard let url = Bundle.main.url(forResource: "stars_fill", withExtension: "json") else {
            throw XCTSkip("stars_fill.json がホストアプリに同梱されていないためスキップ")
        }
        let data = try Data(contentsOf: url)
        let clock = ContinuousClock()
        var decodeTimes: [Duration] = []
        var convertTimes: [Duration] = []
        var dedupeTimes: [Duration] = []
        var fillCount = 0
        measure(metrics: [XCTClockMetric()], options: options) {
            let t0 = clock.now
            guard let entries = try? JSONDecoder().decode([[Double]].self, from: data) else {
                XCTFail("stars_fill.json をデコードできませんでした")
                return
            }
            let t1 = clock.now
            let fill = StarCatalog.makeFillStars(from: entries)
            let t2 = clock.now
            fillCount = StarCatalog.removingDuplicates(of: StarCatalog.namedStars, from: fill).count
            let t3 = clock.now
            decodeTimes.append(t1 - t0)
            convertTimes.append(t2 - t1)
            dedupeTimes.append(t3 - t2)
        }
        XCTAssertGreaterThan(fillCount, 0)
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        print(
            "[perf] starCatalogDecode median: decode \(median(decodeTimes)), "
                + "makeFillStars \(median(convertTimes)), dedupe \(median(dedupeTimes)), rows \(fillCount)"
        )
    }

    // MARK: - Terrain grid decode

    /// 全球標高グリッド (3600×7200 Int16 ≈ 52MB) の ELVZ 展開。初回の星図表示時に 1 度だけ走る。
    func test_perf_terrainGlobalGridDecode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NightScope/Data/elevation_global.bin.z")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("elevation_global.bin.z が未生成のためスキップ")
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            _ = ElevationGridData.load(from: url)
        }
    }
}
