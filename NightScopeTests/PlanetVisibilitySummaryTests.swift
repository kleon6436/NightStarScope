import XCTest
import CoreLocation
@testable import NightScope

final class PlanetVisibilitySummaryTests: XCTestCase {

    // MARK: - Helpers

    private let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
    private let tokyoTZ = TimeZone(identifier: "Asia/Tokyo")!

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

    /// riseTime・setTime が取得できる場合、夜間窓（18:00〜翌 06:00）に収まる。
    func test_planetNightSummaries_riseSetTimesWithinNightWindow() {
        let date = makeDate(year: 2025, month: 6, day: 21, timeZoneIdentifier: "Asia/Tokyo")
        let cal = ObservationTimeZone.gregorianCalendar(timeZone: tokyoTZ)
        let startOfDay = cal.startOfDay(for: date)
        let nightStart = cal.date(byAdding: .hour, value: 18, to: startOfDay)!
        let nextDay    = cal.date(byAdding: .day,  value: 1,  to: startOfDay)!
        let nightEnd   = cal.date(byAdding: .hour, value: 6,  to: nextDay)!

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
}
