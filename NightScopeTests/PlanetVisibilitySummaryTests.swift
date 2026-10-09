import XCTest
import CoreLocation
@testable import NightScope

final class PlanetVisibilitySummaryTests: XCTestCase {

    // MARK: - Helpers

    private let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
    private let tokyoTZ = TestTimeZones.tokyo

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        timeZoneIdentifier: String
    ) -> Date {
        var components = DateComponents()
        components.year  = year
        components.month = month
        components.day   = day
        components.hour  = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: timeZoneIdentifier)
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - planetNightSummaries returns 5 entries

    /// 結果は 5 惑星すべてを含む。
    func test_planetNightSummaries_returnsFivePlanets() {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        XCTAssertEqual(summaries.count, 5)
    }

    // MARK: - Result is sorted in canonical order

    /// 返り値が 水星/金星/火星/木星/土星 の順に並ぶ。
    func test_planetNightSummaries_sortedInCanonicalOrder() {
        let expected = ["水星", "金星", "火星", "木星", "土星"]
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let names = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        ).map(\.name)
        XCTAssertEqual(names, expected)
    }

    // MARK: - Rise/set times fall within the night window

    /// riseTime・setTime が取得できる場合、夜間窓（日没〜日の出）に収まる。
    func test_planetNightSummaries_riseSetTimesWithinNightWindow() throws {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let night = try XCTUnwrap(
            MilkyWayCalculator.sunsetSunriseInterval(date: date, location: tokyo, timeZone: tokyoTZ)
        )
        let nightStart = night.start
        let nightEnd = night.end

        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            if let rise = s.riseTime {
                XCTAssertGreaterThanOrEqual(rise, nightStart - 60,
                    "\(s.name) riseTime \(rise) is before nightStart")
                XCTAssertLessThanOrEqual(rise, nightEnd + 60,
                    "\(s.name) riseTime \(rise) is after nightEnd")
            }
            if let set = s.setTime {
                XCTAssertGreaterThanOrEqual(set, nightStart - 60,
                    "\(s.name) setTime \(set) is before nightStart")
                XCTAssertLessThanOrEqual(set, nightEnd + 60,
                    "\(s.name) setTime \(set) is after nightEnd")
            }
        }
    }

    // MARK: - isVisibleTonight reflects altitude correctly

    /// peakAltitude >= 5 の惑星は isVisibleTonight == true。
    func test_isVisibleTonight_trueWhenAboveHorizon() {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            if s.peakAltitude > 10.0 {
                XCTAssertTrue(s.isVisibleTonight,
                    "\(s.name) should be visible (peakAlt=\(s.peakAltitude))")
            } else {
                XCTAssertFalse(s.isVisibleTonight,
                    "\(s.name) should not be visible (peakAlt=\(s.peakAltitude))")
            }
        }
    }

    // MARK: - Result changes with location

    /// 異なる緯度の地点では peakAltitude が変化する（同一日付）。
    func test_planetNightSummaries_differsWithLocation() {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let tokyoResults = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        // 北緯 60 度の地点（ヘルシンキ付近）
        let helsinki = CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384)
        let utcTZ    = TimeZone(identifier: "UTC")!
        let helsinkiResults = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: helsinki,
            timeZone: utcTZ
        )
        XCTAssertEqual(helsinkiResults.count, 5)
        // 両地点で全惑星の高度が同一になることはない
        let allSame = zip(tokyoResults, helsinkiResults).allSatisfy {
            $0.peakAltitude == $1.peakAltitude
        }
        XCTAssertFalse(allSame, "Peak altitudes should differ between Tokyo and Helsinki")
    }

    // MARK: - localizedName is non-empty for all planets

    /// すべての惑星の localizedName が空文字でない。
    func test_planetNightSummaries_localizedNameNonEmpty() {
        let date = makeDate(year: 2025, month: 9, day: 15, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            XCTAssertFalse(s.localizedName.isEmpty,
                "\(s.name) localizedName must not be empty")
        }
    }

    // MARK: - Azimuth range

    /// 方位角がすべて 0–360° の範囲内に収まる。
    func test_planetNightSummaries_azimuthInRange() {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            if let az = s.transitAzimuth {
                XCTAssertGreaterThanOrEqual(az, 0,   "\(s.name) transitAzimuth < 0")
                XCTAssertLessThan(az, 360,           "\(s.name) transitAzimuth >= 360")
            }
            if let az = s.riseAzimuth {
                XCTAssertGreaterThanOrEqual(az, 0,  "\(s.name) riseAzimuth < 0")
                XCTAssertLessThan(az, 360,          "\(s.name) riseAzimuth >= 360")
            }
            if let az = s.setAzimuth {
                XCTAssertGreaterThanOrEqual(az, 0,  "\(s.name) setAzimuth < 0")
                XCTAssertLessThan(az, 360,          "\(s.name) setAzimuth >= 360")
            }
        }
    }

    // MARK: - interpolateAzimuth

    /// 0°/360° 跨ぎの補間: 350° と 10° の中点 = 0° 付近。
    func test_interpolateAzimuth_crossingZero() {
        let result = MilkyWayCalculator.interpolateAzimuth(350, 10, frac: 0.5)
        // 短弧補間: delta = 10-350 = -340 → wrapped = 20 → midpoint = 350 + 10 = 360 → 0
        XCTAssertEqual(result, 0, accuracy: 1, "Expected ~0° for midpoint of 350° and 10°")
    }

    /// 通常ケース（跨ぎなし）: 10° と 50° の中点 = 30°。
    func test_interpolateAzimuth_normalCase() {
        let result = MilkyWayCalculator.interpolateAzimuth(10, 50, frac: 0.5)
        XCTAssertEqual(result, 30, accuracy: 1e-9)
    }

    // MARK: - altitudeSamples count

    /// altitudeSamples は日没〜日の出を 15 分刻みにした点数（終端を含む）。
    /// 夏至前後の東京は約 9 時間 26 分の夜なので 39 点（18:00–06:00 固定の 49 点より少ない）。
    func test_planetNightSummaries_altitudeSamplesCount() throws {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let night = try XCTUnwrap(
            MilkyWayCalculator.sunsetSunriseInterval(date: date, location: tokyo, timeZone: tokyoTZ)
        )
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            XCTAssertGreaterThanOrEqual(s.altitudeSamples.count, 37, s.name)
            XCTAssertLessThanOrEqual(s.altitudeSamples.count, 41, s.name)
            XCTAssertEqual(s.altitudeSamples.first?.time, night.start, s.name)
            XCTAssertEqual(s.altitudeSamples.last?.time, night.end, s.name)
        }
    }

    // MARK: - 実際の夜（日没〜日の出）に沿ったサンプリング

    /// 冬のヘルシンキは 15 時台に日没・9 時過ぎに日の出のため、18:00〜06:00 固定では
    /// 明け方 8 時台に高く昇る金星（2026-12-06 朝）を取りこぼしていた。
    func test_planetNightSummaries_highLatitudeWinter_coversLateMorningDarkness() throws {
        let helsinki = CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384)
        let helsinkiTZ = try XCTUnwrap(TimeZone(identifier: "Europe/Helsinki"))
        let date = makeDate(year: 2026, month: 12, day: 5, timeZoneIdentifier: helsinkiTZ.identifier)
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: helsinki,
            timeZone: helsinkiTZ
        )
        let venus = try XCTUnwrap(summaries.first { $0.name == "金星" })
        XCTAssertTrue(venus.isVisibleTonight, "peakAlt=\(venus.peakAltitude)")
        XCTAssertGreaterThan(venus.peakAltitude, 15.0)

        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: helsinkiTZ)
        let transit = try XCTUnwrap(venus.transitTime)
        // 最良時刻は翌朝 06:00 より後（旧サンプリング範囲の外）
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: date))
        let sixAM = try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: nextDay))
        XCTAssertGreaterThan(transit, sixAM)

        // サンプリングは 18:00 より前（日没直後）から始まる
        let firstSample = try XCTUnwrap(venus.altitudeSamples.first?.time)
        let sixPM = try XCTUnwrap(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date))
        XCTAssertLessThan(firstSample, sixPM)
    }

    /// 極夜（トロムソの 12 月）は観測日 12:00 から 24 時間を評価する。
    func test_planetNightSummaries_polarNight_samplesFullDayFromNoon() throws {
        let tromso = CLLocationCoordinate2D(latitude: 69.6492, longitude: 18.9553)
        let osloTZ = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let date = makeDate(year: 2026, month: 12, day: 5, timeZoneIdentifier: osloTZ.identifier)
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tromso,
            timeZone: osloTZ
        )
        XCTAssertEqual(summaries.count, 5)
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: osloTZ)
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date))
        for s in summaries {
            XCTAssertEqual(s.altitudeSamples.count, 97, s.name)
            XCTAssertEqual(s.altitudeSamples.first?.time, noon, s.name)
            XCTAssertEqual(s.altitudeSamples.last?.time, noon.addingTimeInterval(24 * 60 * 60), s.name)
            XCTAssertTrue(s.hasDarkSkySamples, s.name)
        }
    }

    // MARK: - Rise nil implies riseAzimuth nil

    /// riseTime が nil の惑星は riseAzimuth も nil。
    func test_planetNightSummaries_noRiseNilAzimuth() {
        // 全惑星を検査して「riseTime が nil なら riseAzimuth も nil」の不変条件を確認する
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries where s.riseTime == nil {
            XCTAssertNil(s.riseAzimuth, "\(s.name): riseTime is nil but riseAzimuth is not nil")
        }
        for s in summaries where s.setTime == nil {
            XCTAssertNil(s.setAzimuth, "\(s.name): setTime is nil but setAzimuth is not nil")
        }
    }

    // MARK: - Azimuth label formatting

    /// riseAzimuth / transitAzimuth / setAzimuth が nil のとき各ラベルは "—"。
    func test_riseAzimuthLabel_nilReturnsPlaceholder() {
        let s = PlanetNightSummary(
            name: "火星", riseTime: nil, transitTime: nil, setTime: nil,
            peakAltitude: 5.0, magnitude: 1.0,
            riseAzimuth: nil, transitAzimuth: nil, setAzimuth: nil
        )
        XCTAssertEqual(s.riseAzimuthLabel(), "—")
        XCTAssertEqual(s.transitAzimuthLabel(), "—")
        XCTAssertEqual(s.setAzimuthLabel(), "—")
    }

    /// riseAzimuth が非 nil のとき riseAzimuthLabel() は度数と方位名を含む。
    func test_riseAzimuthLabel_nonNilContainsDegrees() {
        let s = PlanetNightSummary(
            name: "木星", riseTime: nil, transitTime: nil, setTime: nil,
            peakAltitude: 30.0, magnitude: -2.0,
            riseAzimuth: 90.0, transitAzimuth: 180.0, setAzimuth: 270.0
        )
        // 90° = 東
        XCTAssertTrue(s.riseAzimuthLabel().contains("90"), "Label should contain degree value")
        XCTAssertFalse(s.riseAzimuthLabel() == "—", "Non-nil azimuth should not return placeholder")
        // 180° = 南
        XCTAssertTrue(s.transitAzimuthLabel().contains("180"))
        // 270° = 西
        XCTAssertTrue(s.setAzimuthLabel().contains("270"))
    }

    // MARK: - 空の明るさ（太陽高度）を考慮した可視判定

    /// 白夜（太陽高度が -6° を下回らない夜）では、どの惑星も観測可能とみなさない。
    func test_planetNightSummaries_whiteNight_noPlanetVisible() {
        let longyearbyen = CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469)
        let osloTZ = TimeZone(identifier: "Europe/Oslo")!
        let date = makeDate(year: 2026, month: 6, day: 21, timeZoneIdentifier: osloTZ.identifier)
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: longyearbyen,
            timeZone: osloTZ
        )
        XCTAssertEqual(summaries.count, 5)
        for s in summaries {
            XCTAssertFalse(s.hasDarkSkySamples, "\(s.name)")
            XCTAssertFalse(s.isVisibleTonight, "\(s.name) peakAlt=\(s.peakAltitude)")
            XCTAssertNotEqual(s.observationDifficulty, .nakedEye, "\(s.name)")
        }
    }

    /// 最大高度（南中）時刻は、太陽高度が -6° 未満の暗い時間帯から選ばれる。
    func test_planetNightSummaries_peakIsEvaluatedOnlyWhenSkyIsDark() {
        // 夏至の東京: 18:00 台はまだ太陽が地平線上にある
        let date = makeDate(year: 2026, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let summaries = MilkyWayCalculator.planetNightSummaries(
            date: date,
            location: tokyo,
            timeZone: tokyoTZ
        )
        for s in summaries {
            XCTAssertTrue(s.hasDarkSkySamples)
            guard let transit = s.transitTime else { continue }
            let jd = MilkyWayCalculator.julianDate(from: transit)
            let lst = MilkyWayCalculator.localSiderealTime(jd: jd, longitude: tokyo.longitude)
            let sun = MilkyWayCalculator.sunRaDec(jd: jd)
            let sunAltitude = MilkyWayCalculator.altitude(ra: sun.ra, dec: sun.dec, latitude: tokyo.latitude, lst: lst)
            XCTAssertLessThan(sunAltitude, MilkyWayCalculator.planetObservationSunAltitudeLimit, "\(s.name)")
        }
    }

    // MARK: - 位相角を考慮した等級

    /// 等級は PyEphem 4.2.1 の値と概ね一致する（内惑星 ±0.6 等、外惑星 ±0.3 等）。
    func test_planetPositions_magnitudeMatchesPyEphem() {
        // (JD, 水星以外の期待等級: 金星, 火星, 木星, 土星)
        let cases: [(jd: Double, expected: [String: Double])] = [
            (2461100.5, ["金星": -3.79, "火星": 1.19, "木星": -2.30, "土星": 1.04]),  // 2026-03-01 00:00 UTC
            (2461337.5, ["金星": -3.70, "火星": 0.96, "木星": -1.82, "土星": 0.45]),  // 2026-10-24 00:00 UTC
        ]
        for c in cases {
            let positions = MilkyWayCalculator.planetPositions(jd: c.jd, latitude: 35.68, lst: 0)
            for position in positions {
                guard let expected = c.expected[position.name] else { continue }
                let tolerance = position.name == "金星" ? 0.6 : 0.3
                XCTAssertEqual(position.magnitude, expected, accuracy: tolerance, "jd=\(c.jd) \(position.name)")
            }
        }
    }

    /// 内合付近の金星は細い三日月状のため、満ちた状態の等級（-7 等台）にはならない。
    func test_planetPositions_venusNearInferiorConjunctionIsNotOverBright() throws {
        let positions = MilkyWayCalculator.planetPositions(jd: 2461337.5, latitude: 35.68, lst: 0)  // 2026-10-24
        let venus = try XCTUnwrap(positions.first { $0.name == "金星" })
        XCTAssertGreaterThan(venus.magnitude, -5.0)
        XCTAssertLessThan(venus.magnitude, -3.0)
    }
}
