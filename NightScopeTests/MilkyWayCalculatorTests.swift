import XCTest
import CoreLocation
@testable import NightScope

final class MilkyWayCalculatorTests: XCTestCase {
    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        timeZoneIdentifier: String
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: timeZoneIdentifier)
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - julianDate

    /// J2000.0 エポック (2000-01-01 12:00:00 UTC) → JD = 2451545.0
    func test_julianDate_j2000Epoch() {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let jd = MilkyWayCalculator.julianDate(from: date)
        XCTAssertEqual(jd, 2451545.0, accuracy: 0.001)
    }

    // MARK: - greenwichSiderealTime

    /// J2000.0 では GST = 280.46061837° (式の定数項)
    func test_gst_j2000Epoch() {
        let gst = MilkyWayCalculator.greenwichSiderealTime(jd: 2451545.0)
        XCTAssertEqual(gst, 280.46061837, accuracy: 0.01)
    }

    // MARK: - localSiderealTime

    /// LST = (GST + 経度) mod 360
    func test_lst_tokyoLongitude() {
        let jd = 2451545.0
        let longitude = 139.6503 // 東京
        let lst = MilkyWayCalculator.localSiderealTime(jd: jd, longitude: longitude)
        let gst = MilkyWayCalculator.greenwichSiderealTime(jd: jd)
        var expected = (gst + longitude).truncatingRemainder(dividingBy: 360.0)
        if expected < 0 { expected += 360.0 }
        XCTAssertEqual(lst, expected, accuracy: 0.001)
    }

    // MARK: - altitude

    /// 天頂: HA=0°, dec=lat → altitude = 90°
    func test_altitude_zenith() {
        let latitude = 45.0
        let dec = 45.0
        let ra = 100.0
        let lst = ra // ha = lst - ra = 0
        let alt = MilkyWayCalculator.altitude(ra: ra, dec: dec, latitude: latitude, lst: lst)
        XCTAssertEqual(alt, 90.0, accuracy: 0.001)
    }

    /// 天底: HA=180°, dec=-lat → altitude = -90°
    func test_altitude_nadir() {
        let latitude = 45.0
        let dec = -45.0
        let ra = 0.0
        let lst = 180.0 // ha = 180°
        let alt = MilkyWayCalculator.altitude(ra: ra, dec: dec, latitude: latitude, lst: lst)
        XCTAssertEqual(alt, -90.0, accuracy: 0.001)
    }

    /// 赤道 (lat=0) で HA=90°, dec=0° → altitude = 0°（地平線上）
    func test_altitude_horizon_atEquator() {
        let latitude = 0.0
        let dec = 0.0
        let ra = 0.0
        let lst = 90.0 // ha = 90°
        let alt = MilkyWayCalculator.altitude(ra: ra, dec: dec, latitude: latitude, lst: lst)
        XCTAssertEqual(alt, 0.0, accuracy: 0.001)
    }

    // MARK: - viewingScore

    /// sunAltitude < -20 のとき darknessBonus = (|sunAlt| - 20) * 0.5
    func test_viewingScore_withDarknessBonus() {
        // sunAltitude=-30: darknessBonus = (30-20)*0.5 = 5
        let event = AstroEvent(
            date: Date(),
            galacticCenterAltitude: 20,
            galacticCenterAzimuth: 180,
            sunAltitude: -30,
            moonAltitude: -10,
            moonPhase: 0.1
        )
        let score = MilkyWayCalculator.viewingScore(event)
        XCTAssertEqual(score, 25.0, accuracy: 0.001)
    }

    /// sunAltitude >= -20 のとき darknessBonus = 0
    func test_viewingScore_noBonusWhenNotFullyDark() {
        // sunAltitude=-15: darknessBonus = max(0, -5)*0.5 = 0
        let event = AstroEvent(
            date: Date(),
            galacticCenterAltitude: 20,
            galacticCenterAzimuth: 180,
            sunAltitude: -15,
            moonAltitude: -10,
            moonPhase: 0.1
        )
        let score = MilkyWayCalculator.viewingScore(event)
        XCTAssertEqual(score, 20.0, accuracy: 0.001)
    }

    // MARK: - mergeNearbyWindows

    /// ウィンドウが1つなら変化しない
    func test_mergeNearbyWindows_single_unchanged() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 3600)
        let w = ViewingWindow(start: t0, end: t1, peakTime: t0, peakAltitude: 30, peakAzimuth: 180)
        let result = MilkyWayCalculator.mergeNearbyWindows([w])
        XCTAssertEqual(result.count, 1)
    }

    /// ギャップが閾値以内 (< 30分) ならマージ
    func test_mergeNearbyWindows_gapWithinThreshold_merged() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 3600)
        let t2 = Date(timeIntervalSince1970: 3600 + 1799) // gap = 29分59秒
        let t3 = Date(timeIntervalSince1970: 7200)
        let w1 = ViewingWindow(start: t0, end: t1, peakTime: t0, peakAltitude: 30, peakAzimuth: 180)
        let w2 = ViewingWindow(start: t2, end: t3, peakTime: t2, peakAltitude: 20, peakAzimuth: 190)
        let result = MilkyWayCalculator.mergeNearbyWindows([w1, w2])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, t0)
        XCTAssertEqual(result[0].end, t3)
        XCTAssertEqual(result[0].peakAltitude, 30.0) // より高い高度が採用される
    }

    /// ギャップが閾値超 (> 30分) ならマージしない
    func test_mergeNearbyWindows_gapExceedsThreshold_notMerged() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 3600)
        let t2 = Date(timeIntervalSince1970: 3600 + 1801) // gap = 30分1秒
        let t3 = Date(timeIntervalSince1970: 7200)
        let w1 = ViewingWindow(start: t0, end: t1, peakTime: t0, peakAltitude: 30, peakAzimuth: 180)
        let w2 = ViewingWindow(start: t2, end: t3, peakTime: t2, peakAltitude: 20, peakAzimuth: 190)
        let result = MilkyWayCalculator.mergeNearbyWindows([w1, w2])
        XCTAssertEqual(result.count, 2)
    }

    /// ギャップがちょうど30分ならマージ (gapThreshold = 30 * 60 は `<=` 比較)
    func test_mergeNearbyWindows_exactThresholdGap_merged() {
        let t0 = Date(timeIntervalSince1970: 0)
        let t1 = Date(timeIntervalSince1970: 3600)
        let t2 = Date(timeIntervalSince1970: 3600 + 1800) // gap = ちょうど30分
        let t3 = Date(timeIntervalSince1970: 7200)
        let w1 = ViewingWindow(start: t0, end: t1, peakTime: t0, peakAltitude: 30, peakAzimuth: 180)
        let w2 = ViewingWindow(start: t2, end: t3, peakTime: t2, peakAltitude: 20, peakAzimuth: 190)
        let result = MilkyWayCalculator.mergeNearbyWindows([w1, w2])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - findViewingWindows

    /// galacticCenterVisible が連続するイベントは1つのウィンドウにまとまる
    func test_findViewingWindows_continuousVisible_singleWindow() {
        let base = Date(timeIntervalSince1970: 0)
        // galacticCenterVisible: altitude > 10° && isDark (sunAlt < -18°)
        // 高度15°を使用 (大気差・地物遮蔽を考慮した実用最低高度10°を上回る)
        let events = (0..<4).map { i in
            AstroEvent(
                date: base.addingTimeInterval(Double(i) * 900),
                galacticCenterAltitude: 15.0,
                galacticCenterAzimuth: 180.0,
                sunAltitude: -20.0,
                moonAltitude: -5.0,
                moonPhase: 0.1
            )
        }
        let windows = MilkyWayCalculator.findViewingWindows(events: events)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, base)
        XCTAssertEqual(
            windows[0].end,
            base.addingTimeInterval(4 * MilkyWayCalculator.Constants.sampleIntervalSeconds)
        )
        XCTAssertEqual(
            windows[0].duration,
            4 * MilkyWayCalculator.Constants.sampleIntervalSeconds,
            accuracy: 0.001
        )
    }

    /// galacticCenterVisible なイベントが0件なら空リスト
    func test_findViewingWindows_noVisible_empty() {
        let base = Date(timeIntervalSince1970: 0)
        // sunAlt = -10 → isDark = false → galacticCenterVisible = false
        let events = (0..<4).map { i in
            AstroEvent(
                date: base.addingTimeInterval(Double(i) * 900),
                galacticCenterAltitude: 10.0,
                galacticCenterAzimuth: 180.0,
                sunAltitude: -10.0,
                moonAltitude: -5.0,
                moonPhase: 0.1
            )
        }
        let windows = MilkyWayCalculator.findViewingWindows(events: events)
        XCTAssertTrue(windows.isEmpty)
    }

    /// 連続する N サンプルのウィンドウ duration は N × sampleInterval になる
    func test_findViewingWindows_windowDurationEqualsNTimesSampleInterval() {
        let base = Date(timeIntervalSince1970: 0)
        let interval = Double(MilkyWayCalculator.Constants.sampleIntervalMinutes) * 60  // 900s
        // 4 サンプル (t=0, 900, 1800, 2700) が可視
        let events = (0..<4).map { i in
            AstroEvent(
                date: base.addingTimeInterval(Double(i) * interval),
                galacticCenterAltitude: 15.0,
                galacticCenterAzimuth: 180.0,
                sunAltitude: -20.0,
                moonAltitude: -5.0,
                moonPhase: 0.1
            )
        }
        let windows = MilkyWayCalculator.findViewingWindows(events: events)
        XCTAssertEqual(windows.count, 1)
        // start = t=0, end = t=2700 + 900 = 3600
        XCTAssertEqual(windows[0].start, base)
        XCTAssertEqual(windows[0].end,   base.addingTimeInterval(interval * 4))
        XCTAssertEqual(windows[0].duration, interval * 4, accuracy: 0.001)
    }

    /// 単一サンプルのウィンドウ duration は sampleInterval と等しい
    func test_findViewingWindows_singleSampleWindow_durationEqualsSampleInterval() {
        let base = Date(timeIntervalSince1970: 0)
        let interval = Double(MilkyWayCalculator.Constants.sampleIntervalMinutes) * 60
        let events = [
            AstroEvent(
                date: base,
                galacticCenterAltitude: 15.0,
                galacticCenterAzimuth: 180.0,
                sunAltitude: -20.0,
                moonAltitude: -5.0,
                moonPhase: 0.1
            )
        ]
        let windows = MilkyWayCalculator.findViewingWindows(events: events)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].duration, interval, accuracy: 0.001)
    }

    func test_calculateNightSummary_usesNextLocalMidnightAcrossDstBoundary() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = makeDate(year: 2024, month: 11, day: 3, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        )!
        let expectedPhase = MilkyWayCalculator.moonRaDec(
            jd: MilkyWayCalculator.julianDate(from: nextMidnight)
        ).phase

        let summary = MilkyWayCalculator.calculateNightSummary(
            date: date,
            location: location,
            timeZone: timeZone
        )

        XCTAssertEqual(summary.moonPhaseAtMidnight, expectedPhase, accuracy: 1e-9)
    }

    func test_calculateNightSummary_eventsCoverNextMorningForObservationNight() {
        let timeZone = TestTimeZones.tokyo
        let date = makeDate(year: 2026, month: 4, day: 2, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)

        let summary = MilkyWayCalculator.calculateNightSummary(
            date: date,
            location: location,
            timeZone: timeZone
        )

        XCTAssertEqual(calendar.component(.hour, from: summary.events.first?.date ?? date), 12)
        XCTAssertEqual(calendar.component(.day, from: summary.events.last?.date ?? date), 3)
        XCTAssertEqual(calendar.component(.hour, from: summary.events.last?.date ?? date), 11)
    }

    func test_civilDarknessInterval_returnsFullObservationWindowDuringPolarNight() throws {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let date = makeDate(year: 2026, month: 12, day: 21, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469)

        let interval = try XCTUnwrap(
            MilkyWayCalculator.civilDarknessInterval(
                date: date,
                location: location,
                timeZone: timeZone
            )
        )
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let components = calendar.dateComponents([.hour, .minute], from: interval.start)

        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(interval.duration, 86_400, accuracy: 60)
    }

    func test_civilDarknessInterval_returnsNilDuringMidnightSun() {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let date = makeDate(year: 2026, month: 6, day: 21, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469)

        let interval = MilkyWayCalculator.civilDarknessInterval(
            date: date,
            location: location,
            timeZone: timeZone
        )

        XCTAssertNil(interval)
    }

    // MARK: - galacticToEquatorial

    /// 銀河中心 (l=0, b=0) → RA≈266.4°, Dec≈-29.0° に近似一致する
    func test_galacticToEquatorial_galacticCenter() {
        let result = MilkyWayCalculator.galacticToEquatorial(l: 0, b: 0)
        XCTAssertEqual(result.ra,  266.4, accuracy: 3.0, "銀河中心 RA")
        XCTAssertEqual(result.dec, -29.0, accuracy: 3.0, "銀河中心 Dec")
    }

    /// 北銀極 (l=任意, b=90) → Dec ≈ 27.1° (銀河北極の赤緯)
    func test_galacticToEquatorial_northGalacticPole() {
        let result = MilkyWayCalculator.galacticToEquatorial(l: 0, b: 90)
        XCTAssertEqual(result.dec, 27.1, accuracy: 3.0, "北銀極 Dec")
    }

    /// 出力 RA が常に [0, 360) 範囲に収まる
    func test_galacticToEquatorial_raInRange() {
        for l in stride(from: 0.0, through: 360.0, by: 30.0) {
            for b in [-30.0, 0.0, 30.0] {
                let result = MilkyWayCalculator.galacticToEquatorial(l: l, b: b)
                XCTAssertGreaterThanOrEqual(result.ra, 0.0,   "l=\(l) b=\(b): RA < 0")
                XCTAssertLessThan(          result.ra, 360.0, "l=\(l) b=\(b): RA >= 360")
                XCTAssertGreaterThanOrEqual(result.dec, -90.0, "l=\(l) b=\(b): Dec < -90")
                XCTAssertLessThanOrEqual(   result.dec,  90.0, "l=\(l) b=\(b): Dec > 90")
            }
        }
    }

    // MARK: - 日没・日の出（太陽中心高度 -0.833°）

    /// 12:00 時点で既に太陽が沈んでいる高緯度（ウトキアグヴィク 11 月）でも、
    /// 正午前後の短い昼の後の日没〜翌日の出を返す。
    func test_sunsetSunriseInterval_anchorsAtSolarNoonWhenSunIsDownAtClockNoon() throws {
        let timeZone = TimeZone(identifier: "America/Anchorage")!
        let date = makeDate(year: 2026, month: 11, day: 16, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 71.29, longitude: -156.79)

        let interval = try XCTUnwrap(
            MilkyWayCalculator.sunsetSunriseInterval(date: date, location: location, timeZone: timeZone)
        )
        // PyEphem (horizon -0:34): 日没 14:13 AKST、翌日の出 12:2x AKST
        let expectedSunset = makeDate(year: 2026, month: 11, day: 16, hour: 14, minute: 13, timeZoneIdentifier: timeZone.identifier)
        XCTAssertEqual(interval.start.timeIntervalSince(expectedSunset), 0, accuracy: 3 * 60)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        let end = calendar.dateComponents([.day, .hour], from: interval.end)
        XCTAssertEqual(end.day, 17)
        XCTAssertEqual(end.hour, 12)
        XCTAssertGreaterThan(interval.duration, 20 * 3600)
    }

    /// 標準の日没高度 (-0.833°) を使い、暦の日没・日の出時刻と 3 分以内で一致する。
    func test_findSunsetSunrise_usesStandardRefractionAltitude() throws {
        let timeZone = TestTimeZones.tokyo
        let date = makeDate(year: 2026, month: 8, day: 12, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)

        let times = try XCTUnwrap(
            MilkyWayCalculator.findSunsetSunrise(date: date, location: location, timeZone: timeZone)
        )
        // PyEphem 4.2.1 (horizon -0:50, 大気差なし): 東京 2026-08-12 日没 18:36、08-13 日の出 4:57
        let expectedSunset = makeDate(year: 2026, month: 8, day: 12, hour: 18, minute: 36, timeZoneIdentifier: timeZone.identifier)
        let expectedSunrise = makeDate(year: 2026, month: 8, day: 13, hour: 4, minute: 57, timeZoneIdentifier: timeZone.identifier)
        XCTAssertEqual(times.sunset.timeIntervalSince(expectedSunset), 0, accuracy: 3 * 60)
        XCTAssertEqual(times.sunrise.timeIntervalSince(expectedSunrise), 0, accuracy: 3 * 60)
    }

    /// 夏時間開始の夜でも、日の出を経過秒ではなく時計時刻（PDT）で返す。
    func test_findSunsetSunriseMinutes_returnsWallClockOnDstStartNight() throws {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = makeDate(year: 2026, month: 3, day: 7, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

        let minutes = try XCTUnwrap(
            MilkyWayCalculator.findSunsetSunriseMinutes(date: date, location: location, timeZone: timeZone)
        )
        // PyEphem: 日没 17:54 PST、翌日の出 07:12 PDT
        XCTAssertEqual(minutes.sunsetMinutes, 17 * 60 + 54, accuracy: 3)
        XCTAssertEqual(minutes.sunriseMinutes, 7 * 60 + 12, accuracy: 3)
    }

    /// 極夜では日没・日の出が同じ時計時刻 (12:00) になる。
    func test_findSunsetSunriseMinutes_polarNightReturnsSameClockTime() throws {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let date = makeDate(year: 2026, month: 12, day: 21, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469)

        let minutes = try XCTUnwrap(
            MilkyWayCalculator.findSunsetSunriseMinutes(date: date, location: location, timeZone: timeZone)
        )
        XCTAssertEqual(minutes.sunsetMinutes, 720, accuracy: 0.001)
        XCTAssertEqual(minutes.sunriseMinutes, 720, accuracy: 0.001)
    }

    /// 日没が深夜 0 時を過ぎる夜（6 月のレイキャビク）は、翌日 0 時台の日没から始まる区間を返す。
    func test_sunsetSunriseInterval_sunsetAfterMidnight() throws {
        let timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!
        let date = makeDate(year: 2026, month: 6, day: 21, timeZoneIdentifier: timeZone.identifier)
        let location = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)

        let interval = try XCTUnwrap(
            MilkyWayCalculator.sunsetSunriseInterval(date: date, location: location, timeZone: timeZone)
        )
        let expectedSunset = makeDate(year: 2026, month: 6, day: 22, hour: 0, minute: 4, timeZoneIdentifier: timeZone.identifier)
        let expectedSunrise = makeDate(year: 2026, month: 6, day: 22, hour: 2, minute: 55, timeZoneIdentifier: timeZone.identifier)
        XCTAssertEqual(interval.start.timeIntervalSince(expectedSunset), 0, accuracy: 3 * 60)
        XCTAssertEqual(interval.end.timeIntervalSince(expectedSunrise), 0, accuracy: 3 * 60)
    }

    // MARK: - 月の位置精度

    /// 月の高度（視差補正込み）が PyEphem 4.2.1（大気差なし）と 0.3° 以内で一致する。
    func test_moonHorizontal_matchesPyEphemAtTokyo() {
        let latitude = 35.6762
        let longitude = 139.6503
        let latRad = AngleMath.toRadians(latitude)
        // (UTC 年月日時, PyEphem の高度)
        let cases: [(month: Int, day: Int, hour: Int, altitude: Double)] = [
            (1, 15, 12, -82.230),
            (3, 3, 15, 59.349),
            (5, 20, 9, 52.802),
            (7, 8, 18, 41.373),
            (9, 26, 21, -2.821),
            (11, 30, 3, -6.883),
            (12, 24, 14, 71.253),
        ]
        for c in cases {
            let date = makeDate(year: 2026, month: c.month, day: c.day, hour: c.hour, timeZoneIdentifier: "UTC")
            let jd = MilkyWayCalculator.julianDate(from: date)
            let observer = MilkyWayCalculator.HorizontalObserver(
                cosLat: cos(latRad),
                sinLat: sin(latRad),
                lst: MilkyWayCalculator.localSiderealTime(jd: jd, longitude: longitude)
            )
            let moon = MilkyWayCalculator.moonHorizontal(jd: jd, observer: observer)
            XCTAssertEqual(moon.alt, c.altitude, accuracy: 0.3, "2026-\(c.month)-\(c.day) \(c.hour)h UTC")
        }
    }

    /// 地平線上の月は視差で約 1° 低く見える。
    func test_moonTopocentricAltitude_lowersHorizonAltitudeByParallax() {
        XCTAssertEqual(
            MilkyWayCalculator.moonTopocentricAltitude(geocentricAltitude: 0, parallax: 0.95),
            -0.95,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MilkyWayCalculator.moonTopocentricAltitude(geocentricAltitude: 90, parallax: 0.95),
            90,
            accuracy: 0.001
        )
    }

    // MARK: - planets in NightSummary テストは削除済み（Feature #1 Planet Visibility を撤去）
}

/// 星空マップの夜間スライダーと時計時刻の対応（夏時間・深夜 0 時以降の日没・極夜）を検証する。
final class StarMapDateLogicNightRangeTests: XCTestCase {
    private func makeDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        components.timeZone = timeZone
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private let reykjavik = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)
    private let reykjavikTZ = TimeZone(identifier: "Atlantic/Reykjavik")!

    /// 日没が翌日 0 時台の夜は、開始分を観測日 0:00 からの 1440 分以上で表し、スライダー時刻を翌日に写像する。
    func test_nightRange_sunsetAfterMidnightMapsSliderToNextDay() throws {
        let date = makeDate(2026, 6, 21, timeZone: reykjavikTZ)
        let range = StarMapDateLogic.nightRange(
            for: date,
            location: reykjavik,
            timeZone: reykjavikTZ,
            fallback: .init(startMinutes: 18 * 60, durationMinutes: 600)
        )
        XCTAssertEqual(range.startMinutes, 1_440 + 4, accuracy: 3)
        XCTAssertEqual(range.durationMinutes, 171, accuracy: 4)

        let realMinutes = StarMapDateLogic.nightOffsetToRealMinutes(30, nightStartMinutes: range.startMinutes)
        let mapped = try XCTUnwrap(StarMapDateLogic.date(
            bySettingClockMinutes: realMinutes,
            onObservationDate: date,
            timeZone: reykjavikTZ,
            nightStartMinutes: range.startMinutes
        ))
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: reykjavikTZ)
        XCTAssertEqual(calendar.component(.day, from: mapped), 22)
        XCTAssertEqual(calendar.component(.hour, from: mapped), 0)
        XCTAssertEqual(
            StarMapDateLogic.realMinutesToNightOffset(
                realMinutes,
                nightStartMinutes: range.startMinutes,
                nightDurationMinutes: range.durationMinutes
            ),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapDateLogic.observationDate(for: mapped, timeZone: reykjavikTZ, nightStartMinutes: range.startMinutes),
            date
        )
    }

    /// 日没が翌日 0 時台の夜に参照時刻 01:00 を渡すと、翌日 01:00 を返す。
    func test_resolvedPresentationDate_sunsetAfterMidnightKeepsNightTime() throws {
        let date = makeDate(2026, 6, 21, timeZone: reykjavikTZ)
        let reference = makeDate(2025, 1, 1, 1, 0, timeZone: reykjavikTZ)
        let resolved = try XCTUnwrap(StarMapDateLogic.resolvedPresentationDate(
            for: date,
            referenceDate: reference,
            location: reykjavik,
            timeZone: reykjavikTZ
        ))
        XCTAssertEqual(resolved, makeDate(2026, 6, 22, 1, 0, timeZone: reykjavikTZ))
    }

    /// 夏時間開始の夜は、スライダー最大位置が日の出の時計時刻 (PDT) に一致する。
    func test_nightRange_durationMatchesWallClockOnDstNight() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let location = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let date = makeDate(2026, 3, 7, timeZone: timeZone)
        let range = StarMapDateLogic.nightRange(
            for: date,
            location: location,
            timeZone: timeZone,
            fallback: .init(startMinutes: 18 * 60, durationMinutes: 600)
        )
        let sunrise = MilkyWayCalculator.findSunsetSunriseMinutes(date: date, location: location, timeZone: timeZone)
        XCTAssertEqual(range.startMinutes, sunrise?.sunsetMinutes ?? -1, accuracy: 1)
        XCTAssertEqual(
            StarMapDateLogic.nightOffsetToRealMinutes(range.durationMinutes, nightStartMinutes: range.startMinutes),
            sunrise?.sunriseMinutes ?? -1,
            accuracy: 1
        )
    }

    /// 極夜では夜間区間が終日のため、参照時刻を 12:00 に丸めずそのまま使う。
    func test_resolvedPresentationDate_polarNightKeepsReferenceTime() throws {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let location = CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469)
        let date = makeDate(2026, 12, 21, timeZone: timeZone)

        let evening = try XCTUnwrap(StarMapDateLogic.resolvedPresentationDate(
            for: date,
            referenceDate: makeDate(2025, 1, 1, 21, 7, timeZone: timeZone),
            location: location,
            timeZone: timeZone
        ))
        XCTAssertEqual(evening, makeDate(2026, 12, 21, 21, 7, timeZone: timeZone))

        let morning = try XCTUnwrap(StarMapDateLogic.resolvedPresentationDate(
            for: date,
            referenceDate: makeDate(2025, 1, 1, 3, 0, timeZone: timeZone),
            location: location,
            timeZone: timeZone
        ))
        XCTAssertEqual(morning, makeDate(2026, 12, 22, 3, 0, timeZone: timeZone))
    }
}

/// MilkyWayCalculator の角度計算を現行の出力値に固定する特性テスト。
/// 期待値はリファクタ前のコードを実行して得た値。計算式を意図的に変えた場合のみ更新する。
/// 更新履歴: 惑星の期待値は (1) 軌道要素を JPL Table 1 に合わせた修正（木星 e 変化率 -0.00013253、
/// 長半径の変化率 aRate を追加）と (2) 惑星の夜間サンプリングを 18:00〜06:00 固定から日没〜日の出へ
/// 変更したことに合わせ、Swift 実装を逐語移植した Python で再生成した。
final class MilkyWayCalculatorCharacterizationTests: XCTestCase {
    private let accuracy = 1e-9

    private struct PlanetGolden {
        let name: String
        let altitude: Double
        let azimuth: Double
        let magnitude: Double
        let distanceAU: Double
    }

    private struct EphemerisGolden {
        let jd: Double
        let latitude: Double
        let longitude: Double
        let gst: Double
        let lst: Double
        let sunRA: Double
        let sunDec: Double
        let moonRA: Double
        let moonDec: Double
        let moonPhase: Double
        let planets: [PlanetGolden]
    }

    /// 1968年（J2000 以前）/ 2025年 / 2028年を、東京・シドニー・レイキャビクで評価する。
    private let ephemerisCases: [EphemerisGolden] = [
        EphemerisGolden(
            jd: 2440000.5, latitude: 35.6762, longitude: 139.6503,
            gst: 241.65463699121028, lst: 21.304936991210297,
            sunRA: 60.832097501349033, sunDec: 20.735222451768635,
            moonRA: 24.677970390955274, moonDec: 11.1199350191259, moonPhase: 0.9000815335501197,
            planets: [
                PlanetGolden(name: "水星", altitude: 34.78180254069655, azimuth: 81.64699047677568,
                             magnitude: 0.44687145156425245, distanceAU: 0.8287150913972336),
                PlanetGolden(name: "金星", altitude: 56.63277822622247, azimuth: 112.30695222765459,
                             magnitude: -3.8904618624869416, distanceAU: 1.7150804769257126),
                PlanetGolden(name: "火星", altitude: 46.34666732048459, azimuth: 93.811060428623,
                             magnitude: 1.4643081461020495, distanceAU: 2.533422748603226),
                PlanetGolden(name: "木星", altitude: -21.37020125426606, azimuth: 54.229231439085424,
                             magnitude: -2.0010241023843998, distanceAU: 5.404758758732948),
                PlanetGolden(name: "土星", altitude: 60.672680989186325, azimuth: 180.6898185648289,
                             magnitude: 0.8771066612510056, distanceAU: 10.111670497464866),
            ]
        ),
        EphemerisGolden(
            jd: 2460678.25, latitude: -33.8688, longitude: 151.2093,
            gst: 12.624450793955475, lst: 163.83375079395549,
            sunRA: 283.69106491796879, sunDec: -22.842199992162605,
            moonRA: 321.26719646670057, moonDec: -18.77472343037527, moonPhase: 0.09756259955139576,
            planets: [
                PlanetGolden(name: "水星", altitude: 6.534284493476195, azimuth: 112.54686719180864,
                             magnitude: -0.38090193752332735, distanceAU: 1.1769968620158278),
                PlanetGolden(name: "金星", altitude: -41.81444567812262, azimuth: 164.20560342687077,
                             magnitude: -4.444673774455317, distanceAU: 0.7379660554192765),
                PlanetGolden(name: "火星", altitude: 21.081191950679774, azimuth: 321.23613290527004,
                             magnitude: -1.2432479651581014, distanceAU: 0.6528277752032595),
                PlanetGolden(name: "木星", altitude: -13.931795276016679, azimuth: 287.0119847760995,
                             magnitude: -2.731475067124823, distanceAU: 4.202376899312364),
                PlanetGolden(name: "土星", altitude: -48.09220636977525, azimuth: 183.7793197285681,
                             magnitude: 1.2858303333871781, distanceAU: 10.044399438959942),
            ]
        ),
        EphemerisGolden(
            jd: 2462000.8, latitude: 64.1466, longitude: -21.9426,
            gst: 74.192382547538728, lst: 52.249782547538729,
            sunRA: 147.19663966172325, sunDec: 13.217891756576329,
            moonRA: 102.85180218772956, moonDec: 23.921562643917998, moonPhase: 0.8800597886336586,
            planets: [
                PlanetGolden(name: "水星", altitude: -4.375198336766287, azimuth: 65.58063682913384,
                             magnitude: -0.26044029049877904, distanceAU: 1.2136244952087747),
                PlanetGolden(name: "金星", altitude: 36.07127573637081, azimuth: 121.47577930297824,
                             magnitude: -4.343323553095222, distanceAU: 0.7595661898641424),
                PlanetGolden(name: "火星", altitude: 34.68272967646966, azimuth: 109.8201823133902,
                             magnitude: 1.5688290258691033, distanceAU: 2.246767861263104),
                PlanetGolden(name: "木星", altitude: -13.464116088573478, azimuth: 55.59435278007359,
                             magnitude: -1.7100758792390391, distanceAU: 6.26217787665897),
                PlanetGolden(name: "土星", altitude: 37.78345846619784, azimuth: 196.02166787931642,
                             magnitude: 0.4617918354955625, distanceAU: 8.953372193913253),
            ]
        ),
    ]

    func test_siderealTime_matchesGolden() {
        for golden in ephemerisCases {
            XCTAssertEqual(MilkyWayCalculator.greenwichSiderealTime(jd: golden.jd), golden.gst,
                           accuracy: accuracy, "jd=\(golden.jd)")
            XCTAssertEqual(MilkyWayCalculator.localSiderealTime(jd: golden.jd, longitude: golden.longitude),
                           golden.lst, accuracy: accuracy, "jd=\(golden.jd)")
        }
    }

    func test_sunRaDec_matchesGolden() {
        for golden in ephemerisCases {
            let sun = MilkyWayCalculator.sunRaDec(jd: golden.jd)
            XCTAssertEqual(sun.ra, golden.sunRA, accuracy: accuracy, "jd=\(golden.jd)")
            XCTAssertEqual(sun.dec, golden.sunDec, accuracy: accuracy, "jd=\(golden.jd)")
        }
    }

    func test_moonRaDec_matchesGolden() {
        for golden in ephemerisCases {
            let moon = MilkyWayCalculator.moonRaDec(jd: golden.jd)
            XCTAssertEqual(moon.ra, golden.moonRA, accuracy: accuracy, "jd=\(golden.jd)")
            XCTAssertEqual(moon.dec, golden.moonDec, accuracy: accuracy, "jd=\(golden.jd)")
            XCTAssertEqual(moon.phase, golden.moonPhase, accuracy: accuracy, "jd=\(golden.jd)")
        }
    }

    func test_planetPositions_matchesGolden() {
        for golden in ephemerisCases {
            let positions = MilkyWayCalculator.planetPositions(
                jd: golden.jd,
                latitude: golden.latitude,
                lst: golden.lst
            )
            XCTAssertEqual(positions.map(\.name), golden.planets.map(\.name), "jd=\(golden.jd)")
            for (position, expected) in zip(positions, golden.planets) {
                let label = "jd=\(golden.jd) \(expected.name)"
                XCTAssertEqual(position.altitude, expected.altitude, accuracy: accuracy, label)
                XCTAssertEqual(position.azimuth, expected.azimuth, accuracy: accuracy, label)
                XCTAssertEqual(position.magnitude, expected.magnitude, accuracy: accuracy, label)
                XCTAssertEqual(position.geocentricDistAU, expected.distanceAU, accuracy: accuracy, label)
            }
        }
    }

    func test_galacticToEquatorial_matchesGolden() {
        let cases: [(l: Double, b: Double, ra: Double, dec: Double)] = [
            (0.0, 0.0, 266.40499480104609, -28.936173960138689),
            (123.4, -45.6, 13.20243948041629, 17.270503202983473),
            (-250.0, 60.0, 204.38898715685966, 55.955298661369319),
        ]
        for c in cases {
            let result = MilkyWayCalculator.galacticToEquatorial(l: c.l, b: c.b)
            XCTAssertEqual(result.ra, c.ra, accuracy: accuracy, "l=\(c.l) b=\(c.b)")
            XCTAssertEqual(result.dec, c.dec, accuracy: accuracy, "l=\(c.l) b=\(c.b)")
        }
    }

    func test_interpolateAzimuth_matchesGolden() {
        let cases: [(az0: Double, az1: Double, frac: Double, expected: Double)] = [
            (350.5, 10.25, 0.3, 356.425),
            (10.0, 350.0, 0.9, 352.0),
            (359.0, 1.0, 1.0, 1.0),
            (100.0, 200.0, 0.5, 150.0),
        ]
        for c in cases {
            XCTAssertEqual(MilkyWayCalculator.interpolateAzimuth(c.az0, c.az1, frac: c.frac), c.expected,
                           accuracy: accuracy, "az0=\(c.az0) az1=\(c.az1) frac=\(c.frac)")
        }
    }

    private struct PlanetNightGolden {
        let name: String
        let riseTime: TimeInterval?
        let riseAzimuth: Double?
        let setTime: TimeInterval?
        let setAzimuth: Double?
        let peakAltitude: Double
        let transitAzimuth: Double
        let magnitude: Double
    }

    private struct NightGolden {
        let year: Int
        let month: Int
        let day: Int
        let latitude: Double
        let longitude: Double
        let moonPhaseAtMidnight: Double
        let viewingWindowCount: Int
        let firstEvent: (gcAltitude: Double, gcAzimuth: Double, sunAltitude: Double, moonAltitude: Double)
        let planets: [PlanetNightGolden]
    }

    private let nightCases: [NightGolden] = [
        NightGolden(
            year: 2025, month: 1, day: 15, latitude: 35.6762, longitude: 139.6503,
            moonPhaseAtMidnight: 0.5571634511120888, viewingWindowCount: 0,
            firstEvent: (18.2174558924813, 210.1453554200271, 33.18842232149424, -32.13116732571031),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: 1736974753.0468397, riseAzimuth: 119.80513617799309,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 3.945176870328709,
                                  transitAzimuth: 123.19699772502597, magnitude: -0.45975907059657617),
                PlanetNightGolden(name: "金星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736940908.549375, setAzimuth: 261.26578808647974,
                                  peakAltitude: 35.07829009035552,
                                  transitAzimuth: 226.26477265362956, magnitude: -4.574634825220615),
                PlanetNightGolden(name: "火星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 79.42019564891248,
                                  transitAzimuth: 175.14564865857594, magnitude: -1.4449572020750951),
                PlanetNightGolden(name: "木星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736966759.4224179, setAzimuth: 296.97733626821207,
                                  peakAltitude: 75.90994906817083,
                                  transitAzimuth: 176.07190512769057, magnitude: -2.648977022977218),
                PlanetNightGolden(name: "土星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736941706.7710838, setAzimuth: 260.7215428599125,
                                  peakAltitude: 36.89799100246175,
                                  transitAzimuth: 222.2102394807375, magnitude: 1.315237889013572),
            ]
        ),
        NightGolden(
            year: 2026, month: 6, day: 20, latitude: -33.8688, longitude: 151.2093,
            moonPhaseAtMidnight: 0.20668008404629595, viewingWindowCount: 1,
            firstEvent: (-24.823905259896158, 162.54549032370343, 30.75164387689921, 22.69557692534274),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1781944597.4489903, setAzimuth: 296.4325600170333,
                                  peakAltitude: 12.795374550182462,
                                  transitAzimuth: 307.5260230744066, magnitude: 0.829332012954497),
                PlanetNightGolden(name: "金星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1781948752.3294654, setAzimuth: 294.6732604712471,
                                  peakAltitude: 23.67331638993527,
                                  transitAzimuth: 318.6335863557154, magnitude: -4.01959804995281),
                PlanetNightGolden(name: "火星", riseTime: 1781979420.6555429, riseAzimuth: 67.73687368606322,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 22.22312619791923,
                                  transitAzimuth: 46.870854533521864, magnitude: 1.2966222839638677),
                PlanetNightGolden(name: "木星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1781945985.3019514, setAzimuth: 295.66003796614046,
                                  peakAltitude: 16.682616176170487,
                                  transitAzimuth: 310.7724288280269, magnitude: -1.8307242024398818),
                PlanetNightGolden(name: "土星", riseTime: 1781967661.20436, riseAzimuth: 86.24067833195296,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 52.43182380923936,
                                  transitAzimuth: 11.428638772435319, magnitude: 1.0239814036418247),
            ]
        ),
        NightGolden(
            year: 2027, month: 11, day: 3, latitude: 64.1466, longitude: -21.9426,
            moonPhaseAtMidnight: 0.167847589665512, viewingWindowCount: 0,
            firstEvent: (-52.36684187092224, 328.7960491003946, -37.37858453777931, -47.555830532139),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: 1825311488.2182994, riseAzimuth: 105.68076858495887,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 8.039944820722024,
                                  transitAzimuth: 124.40825689021527, magnitude: -0.5124460372976105),
                PlanetNightGolden(name: "金星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: -4.118512688204039,
                                  transitAzimuth: 227.12030494992015, magnitude: -3.8889191303148114),
                PlanetNightGolden(name: "火星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: -2.8696679513550296,
                                  transitAzimuth: 216.60315672313536, magnitude: 1.3213699014835107),
                PlanetNightGolden(name: "木星", riseTime: 1825298550.1578116, riseAzimuth: 79.10580086072295,
                                  setTime: nil, setAzimuth: nil,
                                  peakAltitude: 27.833768268731355,
                                  transitAzimuth: 151.22954204098042, magnitude: -1.8054944392807553),
                PlanetNightGolden(name: "土星", riseTime: 1825261959.5516527, riseAzimuth: 75.42978740087383,
                                  setTime: 1825311326.7079697, setAzimuth: 284.53565657768775,
                                  peakAltitude: 32.14058720160805,
                                  transitAzimuth: 180.2605234435665, magnitude: 0.3697710438749644),
            ]
        ),
    ]

    private func observationDate(for golden: NightGolden) -> Date {
        var components = DateComponents()
        components.year = golden.year
        components.month = golden.month
        components.day = golden.day
        components.timeZone = TestTimeZones.tokyo
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// 時刻 (Unix 秒, 約 1.8e9) は 1 ulp が約 2.4e-7 秒のため、角度用の 1e-9 では libm の末尾ビット差でも落ちる。
    /// 補間時刻の特性固定には 1 ms で十分なのでこの許容値を使う。
    private let timeAccuracy = 1e-3

    private func assertOptionalEqual(_ actual: Double?, _ expected: Double?, _ message: String,
                                     accuracy: Double? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let expected else {
            XCTAssertNil(actual, message, file: file, line: line)
            return
        }
        guard let actual else {
            XCTFail("nil (expected \(expected)) \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy ?? self.accuracy, message, file: file, line: line)
    }

    func test_planetNightSummaries_matchesGolden() {
        for golden in nightCases {
            let summaries = MilkyWayCalculator.planetNightSummaries(
                date: observationDate(for: golden),
                location: CLLocationCoordinate2D(latitude: golden.latitude, longitude: golden.longitude),
                timeZone: TestTimeZones.tokyo
            )
            XCTAssertEqual(summaries.map(\.name), golden.planets.map(\.name))
            for (summary, expected) in zip(summaries, golden.planets) {
                let label = "\(golden.year)-\(golden.month)-\(golden.day) \(expected.name)"
                assertOptionalEqual(summary.riseTime?.timeIntervalSince1970, expected.riseTime, label, accuracy: timeAccuracy)
                assertOptionalEqual(summary.riseAzimuth, expected.riseAzimuth, label)
                assertOptionalEqual(summary.setTime?.timeIntervalSince1970, expected.setTime, label, accuracy: timeAccuracy)
                assertOptionalEqual(summary.setAzimuth, expected.setAzimuth, label)
                XCTAssertEqual(summary.peakAltitude, expected.peakAltitude, accuracy: accuracy, label)
                assertOptionalEqual(summary.transitAzimuth, expected.transitAzimuth, label)
                XCTAssertEqual(summary.magnitude, expected.magnitude, accuracy: accuracy, label)
            }
        }
    }

    func test_calculateNightSummary_matchesGolden() throws {
        for golden in nightCases {
            let summary = MilkyWayCalculator.calculateNightSummary(
                date: observationDate(for: golden),
                location: CLLocationCoordinate2D(latitude: golden.latitude, longitude: golden.longitude),
                timeZone: TestTimeZones.tokyo
            )
            let label = "\(golden.year)-\(golden.month)-\(golden.day)"
            XCTAssertEqual(summary.moonPhaseAtMidnight, golden.moonPhaseAtMidnight, accuracy: accuracy, label)
            XCTAssertEqual(summary.viewingWindows.count, golden.viewingWindowCount, label)
            let first = try XCTUnwrap(summary.events.first, label)
            XCTAssertEqual(first.galacticCenterAltitude, golden.firstEvent.gcAltitude,
                           accuracy: accuracy, label)
            XCTAssertEqual(first.galacticCenterAzimuth, golden.firstEvent.gcAzimuth,
                           accuracy: accuracy, label)
            XCTAssertEqual(first.sunAltitude, golden.firstEvent.sunAltitude, accuracy: accuracy, label)
            XCTAssertEqual(first.moonAltitude, golden.firstEvent.moonAltitude, accuracy: accuracy, label)
        }
    }

    /// peakTime / peakAltitude / peakAzimuth は同一サンプル (観測スコア最大) から取る
    func test_findViewingWindows_peakFieldsComeFromSameSample() {
        let base = Date(timeIntervalSince1970: 0)
        // 0: 高度は最大だが太陽が浅い (スコア低)、1: 高度はやや低いが空が暗い (スコア高)
        let specs: [(alt: Double, az: Double, sun: Double)] = [
            (40, 150, -19), (35, 170, -60), (30, 190, -19)
        ]
        let events = specs.enumerated().map { i, spec in
            AstroEvent(
                date: base.addingTimeInterval(Double(i) * 900),
                galacticCenterAltitude: spec.alt,
                galacticCenterAzimuth: spec.az,
                sunAltitude: spec.sun,
                moonAltitude: -5.0,
                moonPhase: 0.1
            )
        }
        let windows = MilkyWayCalculator.findViewingWindows(events: events)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].peakTime, events[1].date)
        XCTAssertEqual(windows[0].peakAltitude, 35.0)
        XCTAssertEqual(windows[0].peakAzimuth, 170.0)
    }

    /// 天頂に近い極 (|lat|=90) でも方位角が有限値で返る
    func test_altAz_atPole_returnsFiniteAzimuth() {
        let result = MilkyWayCalculator.altAz(ra: 10, dec: 45, latitude: 90, lst: 100)
        XCTAssertTrue(result.az.isFinite)
        XCTAssertEqual(result.alt, 45, accuracy: 1e-6)
    }
}

/// 月の輝面の向き（Meeus 48 章の位置角 χ と視差角 q）と、その画面描画への反映。
final class MoonBrightLimbTests: XCTestCase {

    /// Meeus 例題 48.a（1992-04-12 0h TD）: 太陽 α0=20.6579°, δ0=8.6964° / 月 α=134.6885°, δ=13.7684° → χ=285.0°
    func test_moonBrightLimbPositionAngle_matchesMeeusExample48a() {
        let chi = MilkyWayCalculator.moonBrightLimbPositionAngle(
            sunRA: 20.6579, sunDec: 8.6964,
            moonRA: 134.6885, moonDec: 13.7684
        )
        XCTAssertEqual(chi, 285.0, accuracy: 0.1)
    }

    /// アプリの太陽・月の位置から求めた χ は PyEphem 4.2.1（地心視位置）から求めた χ と 0.5° 以内で一致する。
    func test_moonBrightLimbPositionAngle_matchesPyEphem() {
        let cases: [(jd: Double, expected: Double)] = [
            (2461043.5, 310.939),          // 2026-01-03 00:00 UTC
            (2461045.0541666667, 90.672),  // 2026-01-04 13:18 UTC
        ]
        for c in cases {
            let sun = MilkyWayCalculator.sunRaDec(jd: c.jd)
            let moon = MilkyWayCalculator.moonRaDec(jd: c.jd)
            let chi = MilkyWayCalculator.moonBrightLimbPositionAngle(
                sunRA: sun.ra, sunDec: sun.dec, moonRA: moon.ra, moonDec: moon.dec
            )
            XCTAssertEqual(chi, c.expected, accuracy: 0.5, "jd=\(c.jd)")
        }
    }

    /// 東京での月の視差角は PyEphem 4.2.1 の Moon.parallactic_angle() と 0.5° 以内で一致する。
    func test_parallacticAngle_matchesPyEphemAtTokyo() {
        let tokyo = (latitude: 35.68, longitude: 139.65)
        let cases: [(jd: Double, expected: Double)] = [
            (2461043.5, 29.682),
            (2461045.0541666667, -61.122),
        ]
        for c in cases {
            let moon = MilkyWayCalculator.moonRaDec(jd: c.jd)
            let lst = MilkyWayCalculator.localSiderealTime(jd: c.jd, longitude: tokyo.longitude)
            let q = MilkyWayCalculator.parallacticAngle(
                hourAngle: lst - moon.ra, declination: moon.dec, latitude: tokyo.latitude
            )
            XCTAssertEqual(q, c.expected, accuracy: 0.5, "jd=\(c.jd)")
        }
    }

    /// 南中時の視差角: 天頂より南の天体は 0°（天頂方向 = 北）、北の天体は 180°。
    func test_parallacticAngle_onMeridian() {
        XCTAssertEqual(MilkyWayCalculator.parallacticAngle(hourAngle: 0, declination: 10, latitude: 35), 0, accuracy: 1e-9)
        XCTAssertEqual(abs(MilkyWayCalculator.parallacticAngle(hourAngle: 0, declination: 60, latitude: 35)), 180, accuracy: 1e-9)
        // 南中前（東側）は負、南中後（西側）は正
        XCTAssertLessThan(MilkyWayCalculator.parallacticAngle(hourAngle: -30, declination: 10, latitude: 35), 0)
        XCTAssertGreaterThan(MilkyWayCalculator.parallacticAngle(hourAngle: 30, declination: 10, latitude: 35), 0)
    }

    /// 日没後の西空の三日月（東京 2026-02-20 18:30 JST、太陽は月のほぼ真下）は輝面が下（地平線側）を向く。
    /// 南半球（シドニー）の同時刻では太陽が月の左下にあり、輝面は左下を向く。
    func test_moonBrightLimbZenithAngle_eveningCrescentPointsTowardSetSun() {
        let jd = 2461091.8958333335  // 2026-02-20 09:30 UTC
        let tokyoAngle = MilkyWayCalculator.moonBrightLimbZenithAngle(
            jd: jd,
            latitude: 35.6762,
            localSiderealTime: MilkyWayCalculator.localSiderealTime(jd: jd, longitude: 139.6503)
        )
        XCTAssertEqual(tokyoAngle, 189.6, accuracy: 1.0)
        let sydneyAngle = MilkyWayCalculator.moonBrightLimbZenithAngle(
            jd: jd,
            latitude: -33.8688,
            localSiderealTime: MilkyWayCalculator.localSiderealTime(jd: jd, longitude: 151.2093)
        )
        XCTAssertEqual(sydneyAngle, 118.0, accuracy: 1.0)
    }

    /// 方位角が右に増え、高度が上に増える単純な投影では、天頂角 0° は画面の上、90° は左（方位角が減る側）を向く。
    func test_moonBrightLimbScreenAngle_followsProjectionOrientation() throws {
        let project: (Double, Double) -> CGPoint? = { altitude, azimuth in
            CGPoint(x: azimuth * 1000, y: -altitude * 1000)
        }
        let up = try XCTUnwrap(StarMapCanvasView.moonBrightLimbScreenAngle(
            zenithAngleDegrees: 0, altitudeDegrees: 0, azimuthDegrees: 180, project: project
        ))
        XCTAssertEqual(up, -Double.pi / 2, accuracy: 1e-6)
        let left = try XCTUnwrap(StarMapCanvasView.moonBrightLimbScreenAngle(
            zenithAngleDegrees: 90, altitudeDegrees: 0, azimuthDegrees: 180, project: project
        ))
        XCTAssertEqual(abs(left), Double.pi, accuracy: 1e-6)
        let down = try XCTUnwrap(StarMapCanvasView.moonBrightLimbScreenAngle(
            zenithAngleDegrees: 180, altitudeDegrees: 0, azimuthDegrees: 180, project: project
        ))
        XCTAssertEqual(down, Double.pi / 2, accuracy: 1e-6)

        // 画面を 90° 回した（ロールした）投影では、天頂方向も画面上で回る
        let rolled: (Double, Double) -> CGPoint? = { altitude, azimuth in
            CGPoint(x: altitude * 1000, y: azimuth * 1000)
        }
        let rolledUp = try XCTUnwrap(StarMapCanvasView.moonBrightLimbScreenAngle(
            zenithAngleDegrees: 0, altitudeDegrees: 0, azimuthDegrees: 180, project: rolled
        ))
        XCTAssertEqual(rolledUp, 0, accuracy: 1e-6)

        // 投影できない場合は nil
        XCTAssertNil(StarMapCanvasView.moonBrightLimbScreenAngle(
            zenithAngleDegrees: 0, altitudeDegrees: 0, azimuthDegrees: 0, project: { _, _ in nil }
        ))
    }

    /// 輝面の向きを指定すると、多角形の輝面側がその向きへ回転する。指定しなければ従来の左右表示。
    func test_moonLitPolygon_rotatesLitSideToBrightLimbAngle() {
        let center = CGPoint(x: 100, y: 100)
        func centroid(_ points: [CGPoint]) -> CGPoint {
            CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
            )
        }
        // 上弦（半月）: 指定なしは右側が光る
        let legacy = centroid(StarMapCanvasView.moonLitPolygon(center: center, radius: 10, phase: 0.25))
        XCTAssertGreaterThan(legacy.x, center.x + 2)
        XCTAssertEqual(legacy.y, center.y, accuracy: 1e-6)

        // 輝面を下（+y）へ向ける
        let down = centroid(StarMapCanvasView.moonLitPolygon(
            center: center, radius: 10, phase: 0.25, brightLimbScreenAngle: Double.pi / 2
        ))
        XCTAssertGreaterThan(down.y, center.y + 2)
        XCTAssertEqual(down.x, center.x, accuracy: 1e-6)

        // 下弦でも向きの指定が優先される（左右反転しない）
        let waningUp = centroid(StarMapCanvasView.moonLitPolygon(
            center: center, radius: 10, phase: 0.75, brightLimbScreenAngle: -Double.pi / 2
        ))
        XCTAssertLessThan(waningUp.y, center.y - 2)
    }
}
