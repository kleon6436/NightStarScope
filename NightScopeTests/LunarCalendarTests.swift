import XCTest
import CoreLocation
@testable import NightScope

final class LunarCalendarTests: XCTestCase {

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let utc = TimeZone(identifier: "UTC")!

    private func instant(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in timeZone: TimeZone) -> Date {
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - phaseEvents (AC1)

    /// 出典: U.S. Naval Observatory, Phases of the Moon 2024
    /// https://aa.usno.navy.mil/api/moon/phases/year?year=2024 （UTC, 分単位）
    private let usno2024: [(String, PrincipalMoonPhase)] = [
        ("2024-01-04T03:30:00Z", .lastQuarter),
        ("2024-01-11T11:57:00Z", .new),
        ("2024-01-18T03:52:00Z", .firstQuarter),
        ("2024-01-25T17:54:00Z", .full),
        ("2024-02-02T23:18:00Z", .lastQuarter),
        ("2024-02-09T22:59:00Z", .new),
        ("2024-02-16T15:01:00Z", .firstQuarter),
        ("2024-02-24T12:30:00Z", .full),
        ("2024-03-03T15:23:00Z", .lastQuarter),
        ("2024-03-10T09:00:00Z", .new),
        ("2024-03-17T04:11:00Z", .firstQuarter),
        ("2024-03-25T07:00:00Z", .full),
        ("2024-04-02T03:15:00Z", .lastQuarter),
        ("2024-04-08T18:21:00Z", .new),
        ("2024-04-15T19:13:00Z", .firstQuarter),
        ("2024-04-23T23:49:00Z", .full),
        ("2024-05-01T11:27:00Z", .lastQuarter),
        ("2024-05-08T03:22:00Z", .new),
        ("2024-05-15T11:48:00Z", .firstQuarter),
        ("2024-05-23T13:53:00Z", .full),
        ("2024-05-30T17:13:00Z", .lastQuarter),
        ("2024-06-06T12:38:00Z", .new),
        ("2024-06-14T05:18:00Z", .firstQuarter),
        ("2024-06-22T01:08:00Z", .full),
        ("2024-06-28T21:53:00Z", .lastQuarter),
        ("2024-07-05T22:57:00Z", .new),
        ("2024-07-13T22:49:00Z", .firstQuarter),
        ("2024-07-21T10:17:00Z", .full),
        ("2024-07-28T02:51:00Z", .lastQuarter),
        ("2024-08-04T11:13:00Z", .new),
        ("2024-08-12T15:19:00Z", .firstQuarter),
        ("2024-08-19T18:26:00Z", .full),
        ("2024-08-26T09:26:00Z", .lastQuarter),
        ("2024-09-03T01:55:00Z", .new),
        ("2024-09-11T06:05:00Z", .firstQuarter),
        ("2024-09-18T02:34:00Z", .full),
        ("2024-09-24T18:50:00Z", .lastQuarter),
        ("2024-10-02T18:49:00Z", .new),
        ("2024-10-10T18:55:00Z", .firstQuarter),
        ("2024-10-17T11:26:00Z", .full),
        ("2024-10-24T08:03:00Z", .lastQuarter),
        ("2024-11-01T12:47:00Z", .new),
        ("2024-11-09T05:55:00Z", .firstQuarter),
        ("2024-11-15T21:28:00Z", .full),
        ("2024-11-23T01:28:00Z", .lastQuarter),
        ("2024-12-01T06:21:00Z", .new),
        ("2024-12-08T15:26:00Z", .firstQuarter),
        ("2024-12-15T09:02:00Z", .full),
        ("2024-12-22T22:18:00Z", .lastQuarter),
        ("2024-12-30T22:27:00Z", .new),
    ]

    func test_phaseEvents_matchUSNO2024WithinFifteenMinutes() {
        let events = LunarCalendar.phaseEvents(from: instant("2024-01-01T00:00:00Z"), to: instant("2025-01-01T00:00:00Z"))
        XCTAssertEqual(events.count, usno2024.count)
        for (iso, kind) in usno2024 {
            let expected = instant(iso)
            let nearest = events
                .filter { $0.kind == kind }
                .min { abs($0.date.timeIntervalSince(expected)) < abs($1.date.timeIntervalSince(expected)) }
            guard let nearest else {
                XCTFail("\(kind) near \(iso) が見つからない")
                continue
            }
            XCTAssertLessThanOrEqual(abs(nearest.date.timeIntervalSince(expected)), 15 * 60, "\(kind) \(iso)")
        }
    }

    func test_phaseEvents_areSortedAndCycleThroughPhases() {
        let events = LunarCalendar.phaseEvents(from: instant("2024-01-01T00:00:00Z"), to: instant("2024-07-01T00:00:00Z"))
        XCTAssertEqual(events.map(\.date), events.map(\.date).sorted())
        let order = PrincipalMoonPhase.allCases
        for (previous, next) in zip(events, events.dropFirst()) {
            let previousIndex = order.firstIndex(of: previous.kind)!
            XCTAssertEqual(next.kind, order[(previousIndex + 1) % order.count])
        }
    }

    // MARK: - month(containing:) (AC2)

    func test_month_returnsOneEntryPerDayWithoutDuplicates() {
        let santiago = TimeZone(identifier: "America/Santiago")!
        let cases: [(Date, TimeZone, Int)] = [
            (localDate(2026, 2, 10, in: tokyo), tokyo, 28),
            (localDate(2028, 2, 10, in: tokyo), tokyo, 29),
            // チリの夏時間開始日（2026-09-06）は 0 時が存在しない
            (localDate(2026, 9, 15, in: santiago), santiago, 30),
        ]
        for (date, timeZone, expectedCount) in cases {
            let calendar = ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
            let days = LunarCalendar.month(containing: date, timeZone: timeZone)
            XCTAssertEqual(days.count, expectedCount, "\(timeZone.identifier)")
            XCTAssertEqual(Set(days.map(\.date)).count, expectedCount)
            XCTAssertEqual(days.map { calendar.component(.day, from: $0.date) }, Array(1...expectedCount))
            for day in days {
                XCTAssertEqual(day.date, calendar.startOfDay(for: day.date))
            }
        }
    }

    // MARK: - NightSummary との一致 (AC3)

    func test_month_phaseMatchesNightSummaryMoonPhaseAtMidnight() {
        let location = CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)
        let identifiers = ["Asia/Tokyo", "UTC", "America/Los_Angeles", "Australia/Sydney"]
        for identifier in identifiers {
            let timeZone = TimeZone(identifier: identifier)!
            let days = LunarCalendar.month(containing: localDate(2026, 10, 15, in: timeZone), timeZone: timeZone)
            XCTAssertEqual(days.count, 31)
            for day in days {
                let summary = MilkyWayCalculator.calculateNightSummary(date: day.date, location: location, timeZone: timeZone)
                XCTAssertEqual(day.phase, summary.moonPhaseAtMidnight, accuracy: 1e-12, "\(identifier) \(day.date)")
            }
        }
    }

    // MARK: - night(for:) (AC4)

    func test_night_switchesAtNoonLocalTime() {
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 10, 13, 11, 59, in: tokyo), timeZone: tokyo), localDate(2026, 10, 12, in: tokyo))
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 10, 13, 12, 0, in: tokyo), timeZone: tokyo), localDate(2026, 10, 13, in: tokyo))
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 10, 14, 11, 59, in: tokyo), timeZone: tokyo), localDate(2026, 10, 13, in: tokyo))
    }

    func test_night_dependsOnTimeZone() {
        // 03:30 UTC は UTC では前日の夜、Asia/Tokyo（12:30）では当日の夜
        let moment = instant("2026-10-13T03:30:00Z")
        XCTAssertEqual(LunarCalendar.night(for: moment, timeZone: utc), localDate(2026, 10, 12, in: utc))
        XCTAssertEqual(LunarCalendar.night(for: moment, timeZone: tokyo), localDate(2026, 10, 13, in: tokyo))
    }

    func test_night_boundaryHoldsOnDaylightSavingTransitionDay() {
        // America/Los_Angeles の夏時間開始日（2026-03-08, 02:00 → 03:00）
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 3, 8, 11, 59, in: losAngeles), timeZone: losAngeles), localDate(2026, 3, 7, in: losAngeles))
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 3, 8, 12, 0, in: losAngeles), timeZone: losAngeles), localDate(2026, 3, 8, in: losAngeles))
        // 0 時が存在しない日の翌日午前は、その日（01:00 始まり）の夜に属する
        let santiago = TimeZone(identifier: "America/Santiago")!
        let santiagoCalendar = ObservationTimeZone.gregorianCalendar(timeZone: santiago)
        let transitionNight = santiagoCalendar.startOfDay(for: localDate(2026, 9, 6, 12, 0, in: santiago))
        XCTAssertEqual(LunarCalendar.night(for: localDate(2026, 9, 7, 6, 0, in: santiago), timeZone: santiago), transitionNight)
    }

    // MARK: - moonAge (AC5)

    func test_moonAge_resetsAtNewMoonNightAndOtherwiseIncreases() {
        let allNewMoons = LunarCalendar.phaseEvents(from: instant("2023-11-01T00:00:00Z"), to: instant("2025-02-01T00:00:00Z"))
            .filter { $0.kind == .new }
            .map(\.date)
        var days: [LunarDay] = []
        for month in 1...12 {
            days += LunarCalendar.month(containing: localDate(2024, month, 15, in: tokyo), timeZone: tokyo)
        }
        var newMoonNightCount = 0
        for (index, day) in days.enumerated() {
            XCTAssertGreaterThanOrEqual(day.moonAge, 0)
            XCTAssertLessThan(day.moonAge, 30)
            guard let event = day.principalEvent, event.kind == .new else {
                if index > 0, days[index - 1].principalEvent?.kind != .new {
                    XCTAssertGreaterThan(day.moonAge, days[index - 1].moonAge, "\(day.date)")
                }
                continue
            }
            newMoonNightCount += 1
            let previousNewMoon = allNewMoons.last { $0 < event.date }!
            let previousLunationDays = event.date.timeIntervalSince(previousNewMoon) / 86400
            XCTAssertTrue(day.moonAge < 0.5 || day.moonAge > previousLunationDays - 0.5, "\(day.date) age=\(day.moonAge)")
            if index + 1 < days.count {
                XCTAssertGreaterThanOrEqual(days[index + 1].moonAge, 0.5)
                XCTAssertLessThanOrEqual(days[index + 1].moonAge, 1.5)
            }
        }
        XCTAssertGreaterThanOrEqual(newMoonNightCount, 12)
    }

    // MARK: - 暗い夜・月明かり (AC6)

    func test_isDarkNight_andMoonlightLevelBoundaries() {
        func day(illumination: Double) -> LunarDay {
            LunarDay(date: Date(), phase: 0, moonAge: 0, illumination: illumination, principalEvent: nil)
        }
        XCTAssertTrue(day(illumination: 0.1499).isDarkNight)
        XCTAssertFalse(day(illumination: 0.15).isDarkNight)
        XCTAssertEqual(day(illumination: 0.1499).moonlightLevel, .low)
        XCTAssertEqual(day(illumination: 0.15).moonlightLevel, .moderate)
        XCTAssertEqual(day(illumination: 0.6).moonlightLevel, .high)
    }

    func test_supportedYears() {
        XCTAssertEqual(LunarCalendar.supportedYears, 1900...2100)
    }
}
