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

    // MARK: - planets in NightSummary テストは削除済み（Feature #1 Planet Visibility を撤去）
}

/// MilkyWayCalculator の角度計算を現行の出力値に固定する特性テスト。
/// 期待値はリファクタ前のコードを実行して得た値。計算式を意図的に変えた場合のみ更新する。
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
            moonRA: 24.744094477608865, moonDec: 10.959535727980091, moonPhase: 0.90003367661493028,
            planets: [
                PlanetGolden(name: "水星", altitude: 34.781835535765744, azimuth: 81.647017461286325,
                             magnitude: -2.7954146205756687, distanceAU: 0.82871671970404737),
                PlanetGolden(name: "金星", altitude: 56.632778052743951, azimuth: 112.30695174439839,
                             magnitude: -3.9329529139327053, distanceAU: 1.7150834721586161),
                PlanetGolden(name: "火星", altitude: 46.346662390086166, azimuth: 93.811054388250042,
                             magnitude: 1.4312172485493075, distanceAU: 2.5334303933812166),
                PlanetGolden(name: "木星", altitude: -21.370115537665001, azimuth: 54.229278866193937,
                             magnitude: -2.0733272100755382, distanceAU: 5.4047214258400595),
                PlanetGolden(name: "土星", altitude: 60.677395347006822, azimuth: 180.66633622911971,
                             magnitude: 1.0048582076540029, distanceAU: 10.111734254833129),
            ]
        ),
        EphemerisGolden(
            jd: 2460678.25, latitude: -33.8688, longitude: 151.2093,
            gst: 12.624450793955475, lst: 163.83375079395549,
            sunRA: 283.69106491796879, sunDec: -22.842199992162605,
            moonRA: 319.72731074454714, moonDec: -19.098638563098387, moonPhase: 0.093427499035108968,
            planets: [
                PlanetGolden(name: "水星", altitude: 6.5342994719240872, azimuth: 112.54685460955415,
                             magnitude: -1.9072914940267334, distanceAU: 1.1769955061876394),
                PlanetGolden(name: "金星", altitude: -41.81444740189135, azimuth: 164.2056070239795,
                             magnitude: -5.7663432961461547, distanceAU: 0.73796502219753646),
                PlanetGolden(name: "火星", altitude: 21.081218999691917, azimuth: 321.23617276851292,
                             magnitude: -1.4060890790285858, distanceAU: 0.65282428610666354),
                PlanetGolden(name: "木星", altitude: -13.931757551064488, azimuth: 287.01201702763007,
                             magnitude: -2.7529815766219894, distanceAU: 4.2024062395167752),
                PlanetGolden(name: "土星", altitude: -48.089181262630987, azimuth: 183.76538144798718,
                             magnitude: 1.0467307618171251, distanceAU: 10.045074037842303),
            ]
        ),
        EphemerisGolden(
            jd: 2462000.8, latitude: 64.1466, longitude: -21.9426,
            gst: 74.192382547538728, lst: 52.249782547538729,
            sunRA: 147.19663966172325, sunDec: 13.217891756576329,
            moonRA: 103.75082706022624, moonDec: 23.132623701481087, moonPhase: 0.8825959831627137,
            planets: [
                PlanetGolden(name: "水星", altitude: -4.3752140503284451, azimuth: 65.580621093072054,
                             magnitude: -1.7797222531650434, distanceAU: 1.2136228958914006),
                PlanetGolden(name: "金星", altitude: 36.071277203856567, azimuth: 121.47578332694313,
                             magnitude: -5.6934982172325972, distanceAU: 0.75956497125683542),
                PlanetGolden(name: "火星", altitude: 34.682713182028621, azimuth: 109.82015373237687,
                             magnitude: 1.1996403159223035, distanceAU: 2.2467615758382435),
                PlanetGolden(name: "木星", altitude: -13.464144483642455, azimuth: 55.594321316577322,
                             magnitude: -1.7344922411880184, distanceAU: 6.2622112654772417),
                PlanetGolden(name: "土星", altitude: 37.778744014506557, azimuth: 196.03400678501299,
                             magnitude: 0.70889784600420036, distanceAU: 8.9529842910855884),
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
            moonPhaseAtMidnight: 0.55976541288434623, viewingWindowCount: 0,
            firstEvent: (18.217455892481304, 210.1453554200271, 33.188422321494244, -30.969832992939939),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: 1736974751.0796528, riseAzimuth: 119.79340358531016,
                                  setTime: nil, setAzimuth: nil, peakAltitude: 0.14478912700932942,
                                  transitAzimuth: 119.91043346176924, magnitude: -1.4522443760337238),
                PlanetNightGolden(name: "金星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736940908.2760425, setAzimuth: 261.26400903457903,
                                  peakAltitude: 29.120747093936934,
                                  transitAzimuth: 234.90307653126533, magnitude: -6.0652910963394921),
                PlanetNightGolden(name: "火星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil, peakAltitude: 79.417812646646993,
                                  transitAzimuth: 185.05701779563321, magnitude: -1.4224263993309632),
                PlanetNightGolden(name: "木星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736966757.8944156, setAzimuth: 296.96779696820505,
                                  peakAltitude: 75.912639402480394,
                                  transitAzimuth: 183.73775625132382, magnitude: -2.6873900080709996),
                PlanetNightGolden(name: "土星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1736941704.0294647, setAzimuth: 260.71777740431963,
                                  peakAltitude: 31.247447644997639,
                                  transitAzimuth: 231.36723839766421, magnitude: 1.0831241183983291),
            ]
        ),
        NightGolden(
            year: 2026, month: 6, day: 20, latitude: -33.8688, longitude: 151.2093,
            moonPhaseAtMidnight: 0.20267923367873159, viewingWindowCount: 1,
            firstEvent: (-24.823905259896158, 162.54549032370343, 30.751643876899209, 23.529049395202641),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil, peakAltitude: -4.4005895990495185,
                                  transitAzimuth: 293.24057303921745, magnitude: -2.7858173858883881),
                PlanetNightGolden(name: "金星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1781948753.7896223, setAzimuth: 294.66367614914975,
                                  peakAltitude: 8.3997799143880094,
                                  transitAzimuth: 301.40463695206171, magnitude: -4.8611490159089223),
                PlanetNightGolden(name: "火星", riseTime: 1781979419.7914689, riseAzimuth: 67.742689527988915,
                                  setTime: nil, setAzimuth: nil, peakAltitude: 27.331811683799952,
                                  transitAzimuth: 39.31791098312987, magnitude: 0.90533879120438465),
                PlanetNightGolden(name: "木星", riseTime: nil, riseAzimuth: nil,
                                  setTime: nil, setAzimuth: nil, peakAltitude: -0.04011335289394647,
                                  transitAzimuth: 295.61809361240904, magnitude: -1.8511527171066433),
                PlanetNightGolden(name: "土星", riseTime: 1781967657.790566, riseAzimuth: 86.247324732805268,
                                  setTime: nil, setAzimuth: nil, peakAltitude: 52.978288786637364,
                                  transitAzimuth: 2.7787703345689758, magnitude: 0.92625391825693804),
            ]
        ),
        NightGolden(
            year: 2027, month: 11, day: 3, latitude: 64.1466, longitude: -21.9426,
            moonPhaseAtMidnight: 0.16806223368024703, viewingWindowCount: 0,
            firstEvent: (-52.366841870922237, 328.79604910039461, -37.378584537779311, -47.270646348035385),
            planets: [
                PlanetNightGolden(name: "水星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1825261587.2757006, setAzimuth: 254.75483795850158,
                                  peakAltitude: 19.334813357923309,
                                  transitAzimuth: 179.56188295269558, magnitude: -2.9760676332730021),
                PlanetNightGolden(name: "金星", riseTime: 1825243743.4733818, riseAzimuth: 145.55137770178993,
                                  setTime: 1825261614.4789228, setAzimuth: 214.2216228745971,
                                  peakAltitude: 4.7469970169796216,
                                  transitAzimuth: 181.53104985203453, magnitude: -4.1455354669253985),
                PlanetNightGolden(name: "火星", riseTime: 1825248781.9330196, riseAzimuth: 154.77923440734637,
                                  setTime: 1825262021.2015114, setAzimuth: 205.16361247915657,
                                  peakAltitude: 2.6084246585284889,
                                  transitAzimuth: 181.4998552144728, magnitude: 0.97251649430327314),
                PlanetNightGolden(name: "木星", riseTime: nil, riseAzimuth: nil,
                                  setTime: 1825260169.3523657, setAzimuth: 280.96121175221839,
                                  peakAltitude: 30.621866105389373,
                                  transitAzimuth: 178.78464469648497, magnitude: -1.8444336546473235),
                PlanetNightGolden(name: "土星", riseTime: 1825261959.8864291, riseAzimuth: 75.444245978010869,
                                  setTime: nil, setAzimuth: nil, peakAltitude: 23.503456580815548,
                                  transitAzimuth: 128.58404153783533, magnitude: 0.58123384555948299),
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

    private func assertOptionalEqual(_ actual: Double?, _ expected: Double?, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let expected else {
            XCTAssertNil(actual, message, file: file, line: line)
            return
        }
        guard let actual else {
            XCTFail("nil (expected \(expected)) \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
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
                assertOptionalEqual(summary.riseTime?.timeIntervalSince1970, expected.riseTime, label)
                assertOptionalEqual(summary.riseAzimuth, expected.riseAzimuth, label)
                assertOptionalEqual(summary.setTime?.timeIntervalSince1970, expected.setTime, label)
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
}
