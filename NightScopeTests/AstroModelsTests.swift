import XCTest
import CoreLocation
import AppKit
@testable import NightScope

final class AstroModelsTests: XCTestCase {
    private func makeOffsetDate(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZoneIdentifier: String = "Asia/Tokyo"
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

    private func makeEvent(
        date: Date,
        sunAltitude: Double = -20,
        moonAltitude: Double = -5,
        moonPhase: Double = 0.1
    ) -> AstroEvent {
        AstroEvent(
            date: date,
            galacticCenterAltitude: 25,
            galacticCenterAzimuth: 180,
            sunAltitude: sunAltitude,
            moonAltitude: moonAltitude,
            moonPhase: moonPhase
        )
    }

    private func makeWeatherHour(
        date: Date,
        cloud: Double = 10,
        precipitation: Double = 0,
        weatherCode: Int = 0
    ) -> HourlyWeather {
        HourlyWeather(
            date: date,
            temperatureCelsius: 10,
            cloudCoverPercent: cloud,
            precipitationMM: precipitation,
            windSpeedKmh: 5,
            humidityPercent: 50,
            dewpointCelsius: 3,
            weatherCode: weatherCode,
            visibilityMeters: 20000,
            windGustsKmh: 10,
            windSpeedKmh500hpa: nil
        )
    }

    private func makeSummary(
        events: [AstroEvent],
        timeZoneIdentifier: String = "Asia/Tokyo"
    ) -> NightSummary {
        NightSummary(
            date: events.first?.date ?? Date(),
            location: CLLocationCoordinate2D(latitude: 35.0, longitude: 135.0),
            events: events,
            viewingWindows: [],
            moonPhaseAtMidnight: 0.1,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func test_weatherAwareObservableWindow_mergesAcrossMidnight() {
        let evening = makeDate(2026, 4, 2, 23, 45)
        let morning = makeDate(2026, 4, 3, 0, 0)

        let summary = makeSummary(events: [
            makeEvent(date: evening),
            makeEvent(date: morning)
        ])

        let hours = [
            makeWeatherHour(date: makeDate(2026, 4, 2, 23, 0)),
            makeWeatherHour(date: makeDate(2026, 4, 3, 0, 0))
        ]

        let window = summary.weatherAwareObservableWindow(nighttimeHours: hours)
        XCTAssertEqual(window?.start, evening)
        XCTAssertEqual(window?.end, morning.addingTimeInterval(15 * 60))
    }

    func test_weatherAwareObservableWindow_returnsNilWhenMoonTooBright() {
        let date = makeDate(2026, 4, 2, 22, 0)
        let summary = makeSummary(events: [
            makeEvent(date: date, moonAltitude: 20, moonPhase: 0.5)
        ])

        let hours = [
            makeWeatherHour(date: date, cloud: 0, precipitation: 0, weatherCode: 0)
        ]

        XCTAssertNil(summary.weatherAwareObservableWindow(nighttimeHours: hours))
    }

    func test_weatherAwareRangeText_returnsMoonLightWhenWeatherClear() {
        let date = makeDate(2026, 4, 2, 22, 0)
        let summary = makeSummary(events: [
            makeEvent(date: date, moonAltitude: 30, moonPhase: 0.5)
        ])

        let hours = [
            makeWeatherHour(date: date, cloud: 0, precipitation: 0, weatherCode: 0)
        ]

        XCTAssertEqual(summary.weatherAwareRangeText(nighttimeHours: hours), L10n.tr("月明かり"))
    }

    func test_weatherAwareRangeText_returnsEmptyWhenWeatherBad() {
        let date = makeDate(2026, 4, 2, 22, 0)
        let summary = makeSummary(events: [
            makeEvent(date: date, moonAltitude: -10, moonPhase: 0.1)
        ])

        let hours = [
            makeWeatherHour(date: date, cloud: 90, precipitation: 1.0, weatherCode: 61)
        ]

        XCTAssertEqual(summary.weatherAwareRangeText(nighttimeHours: hours), "")
    }

    func test_weatherAwareObservableWindow_distinguishesRepeatedDstHours() {
        let losAngeles = "America/Los_Angeles"
        let firstHour = makeOffsetDate("2024-11-03T23:00:00-08:00")
        let firstEvent = makeOffsetDate("2024-11-03T23:15:00-08:00")
        let secondHour = makeOffsetDate("2024-11-04T01:00:00-08:00")
        let secondEvent = makeOffsetDate("2024-11-04T01:15:00-08:00")
        let summary = makeSummary(
            events: [
                makeEvent(date: firstEvent),
                makeEvent(date: secondEvent)
            ],
            timeZoneIdentifier: losAngeles
        )

        let hours = [
            makeWeatherHour(date: firstHour, cloud: 95, precipitation: 1.0, weatherCode: 61),
            makeWeatherHour(date: secondHour, cloud: 0, precipitation: 0, weatherCode: 0)
        ]

        let window = summary.weatherAwareObservableWindow(nighttimeHours: hours)
        XCTAssertEqual(window?.start, secondEvent)
        XCTAssertEqual(window?.end, secondEvent.addingTimeInterval(15 * 60))
    }

    func test_weatherAwareObservableWindow_mergesAcrossMidnightOnDstEndNight() {
        let losAngeles = "America/Los_Angeles"
        let morning = makeOffsetDate("2024-11-04T00:00:00-08:00")
        let evening = makeOffsetDate("2024-11-03T23:45:00-08:00")
        let summary = makeSummary(
            events: [
                makeEvent(date: evening),
                makeEvent(date: morning)
            ],
            timeZoneIdentifier: losAngeles
        )

        let hours = [
            makeWeatherHour(date: evening),
            makeWeatherHour(date: morning)
        ]

        let window = summary.weatherAwareObservableWindow(nighttimeHours: hours)
        XCTAssertEqual(window?.start, evening)
        XCTAssertEqual(window?.end, morning.addingTimeInterval(15 * 60))
    }

    func test_weatherAwareRangeText_returnsNilWhenNightWeatherCoverageIsIncomplete() {
        let evening = makeDate(2026, 4, 2, 23, 45)
        let morning = makeDate(2026, 4, 3, 0, 0)
        let summary = makeSummary(events: [
            makeEvent(date: evening),
            makeEvent(date: morning)
        ])

        let hours = [
            makeWeatherHour(date: makeDate(2026, 4, 2, 23, 0))
        ]

        XCTAssertNil(summary.weatherAwareRangeText(nighttimeHours: hours))
    }

    func test_weatherAwareRangeText_returnsPartialRangeForCurrentNight() {
        let referenceDate = makeDate(2026, 4, 2, 12, 0)
        let evening = makeDate(2026, 4, 2, 23, 45)
        let morning = makeDate(2026, 4, 3, 0, 0)
        let summary = NightSummary(
            date: makeDate(2026, 4, 2, 0, 0),
            location: CLLocationCoordinate2D(latitude: 35.0, longitude: 135.0),
            events: [
                makeEvent(date: evening),
                makeEvent(date: morning)
            ],
            viewingWindows: [],
            moonPhaseAtMidnight: 0.1,
            timeZoneIdentifier: "Asia/Tokyo"
        )

        let hours = [
            makeWeatherHour(date: makeDate(2026, 4, 2, 23, 0))
        ]

        XCTAssertEqual(
            summary.weatherAwareRangeText(
                nighttimeHours: hours,
                referenceDate: referenceDate
            ),
            "\(evening.nightTimeString(timeZone: summary.timeZone)) 〜 \(morning.nightTimeString(timeZone: summary.timeZone))"
        )
    }

    func test_weatherAwareRangeText_returnsMorningPartialRangeForCurrentNight() {
        let referenceDate = makeDate(2026, 4, 2, 12, 0)
        let evening = makeDate(2026, 4, 2, 23, 45)
        let morning = makeDate(2026, 4, 3, 0, 0)
        let summary = NightSummary(
            date: makeDate(2026, 4, 2, 0, 0),
            location: CLLocationCoordinate2D(latitude: 35.0, longitude: 135.0),
            events: [
                makeEvent(date: evening),
                makeEvent(date: morning)
            ],
            viewingWindows: [],
            moonPhaseAtMidnight: 0.1,
            timeZoneIdentifier: "Asia/Tokyo"
        )

        let hours = [
            makeWeatherHour(date: makeDate(2026, 4, 3, 0, 0))
        ]

        XCTAssertEqual(
            summary.weatherAwareRangeText(
                nighttimeHours: hours,
                referenceDate: referenceDate
            ),
            "\(morning.nightTimeString(timeZone: summary.timeZone)) 〜 \(morning.addingTimeInterval(15 * 60).nightTimeString(timeZone: summary.timeZone))"
        )
    }

    func test_starCatalogMakeFillStars_skipsMalformedRows() {
        let stars = StarCatalog.makeFillStars(from: [
            [15.0, -20.0, 1.2, 0.4],
            [120.0, 45.0],
            [210.0, 30.0, 2.8]
        ])

        XCTAssertEqual(stars.count, 2)
        XCTAssertEqual(stars[0].ra, 15.0, accuracy: 0.0001)
        XCTAssertEqual(stars[0].dec, -20.0, accuracy: 0.0001)
        XCTAssertEqual(stars[0].magnitude, 1.2, accuracy: 0.0001)
        XCTAssertEqual(stars[0].colorIndex ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(stars[1].ra, 210.0, accuracy: 0.0001)
        XCTAssertNil(stars[1].colorIndex)
    }

    func test_terrainProfileInterpolatesAndWrapsAzimuth() {
        let profile = TerrainProfile(horizonAngles: (0..<72).map(Double.init))

        XCTAssertEqual(profile.horizonAngle(forAzimuth: 7.5), 1.5, accuracy: 0.0001)
        XCTAssertEqual(profile.horizonAngle(forAzimuth: -2.5), 35.5, accuracy: 0.0001)
    }

    func test_planetNightSummaryObservationDifficulty_matchesBrightnessAndAltitude() {
        let date = makeDate(2026, 4, 2, 22, 0)

        let nakedEye = PlanetNightSummary(
            name: "金星",
            riseTime: date,
            transitTime: date,
            setTime: date,
            peakAltitude: 30,
            magnitude: -4.0
        )
        XCTAssertEqual(nakedEye.observationDifficulty, .nakedEye)
        XCTAssertEqual(nakedEye.observationDifficulty.systemImage, "eye.fill")
        XCTAssertEqual(nakedEye.observationDifficulty.localizedLabel, L10n.tr("肉眼"))

        let binoculars = PlanetNightSummary(
            name: "土星",
            riseTime: date,
            transitTime: date,
            setTime: date,
            peakAltitude: 12,
            magnitude: 3.0
        )
        XCTAssertEqual(binoculars.observationDifficulty, .binoculars)
        XCTAssertEqual(binoculars.observationDifficulty.systemImage, "binoculars.fill")
        XCTAssertEqual(binoculars.observationDifficulty.localizedLabel, L10n.tr("双眼鏡"))

        let telescope = PlanetNightSummary(
            name: "水星",
            riseTime: nil,
            transitTime: nil,
            setTime: nil,
            peakAltitude: 6,
            magnitude: 1.5
        )
        XCTAssertEqual(telescope.observationDifficulty, .telescope)
        XCTAssertEqual(telescope.observationDifficulty.systemImage, "viewfinder")
        XCTAssertEqual(telescope.observationDifficulty.localizedLabel, L10n.tr("望遠鏡"))

        let nakedEyeColor = NSColor(nakedEye.observationDifficulty.color).usingColorSpace(.deviceRGB)!
        XCTAssertEqual(nakedEyeColor.redComponent, 0.1882353, accuracy: 0.0001)
        XCTAssertEqual(nakedEyeColor.greenComponent, 0.81960785, accuracy: 0.0001)
        XCTAssertEqual(nakedEyeColor.blueComponent, 0.34509802, accuracy: 0.0001)
    }

    func test_planetNightSummaryObservationDifficulty_boundaryValues() {
        let base = PlanetNightSummary(
            name: "木星",
            riseTime: nil,
            transitTime: nil,
            setTime: nil,
            peakAltitude: 0,
            magnitude: 0
        )

        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 25, magnitude: 0.5).observationDifficulty,
            .nakedEye
        )
        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 24.9, magnitude: 0.5).observationDifficulty,
            .nakedEye
        )
        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 15, magnitude: 2.0).observationDifficulty,
            .nakedEye
        )
        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 14.9, magnitude: 2.0).observationDifficulty,
            .binoculars
        )
        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 10, magnitude: 4.0).observationDifficulty,
            .telescope
        )
        XCTAssertEqual(
            PlanetNightSummary(name: base.name, riseTime: nil, transitTime: nil, setTime: nil, peakAltitude: 9.9, magnitude: 4.0).observationDifficulty,
            .telescope
        )
    }

    // MARK: - 深夜 0 時以降に始まる暗夜

    /// 天文薄明が深夜 0 時以降に始まる夜（例: 6 月の A Coruña）でも暗夜の開始・終了を返す。
    func test_darkRange_whenDarknessStartsAfterMidnight() {
        let timeZoneIdentifier = "Europe/Madrid"
        let start = makeDate(2026, 6, 21, 12, 0, timeZoneIdentifier: timeZoneIdentifier)
        let darkStart = makeDate(2026, 6, 22, 0, 45, timeZoneIdentifier: timeZoneIdentifier)
        let darkEnd = makeDate(2026, 6, 22, 4, 45, timeZoneIdentifier: timeZoneIdentifier)
        let events = (0..<96).map { step -> AstroEvent in
            let date = start.addingTimeInterval(Double(step) * 15 * 60)
            let isDark = date >= darkStart && date < darkEnd
            return makeEvent(date: date, sunAltitude: isDark ? -19 : -10)
        }
        let summary = makeSummary(events: events, timeZoneIdentifier: timeZoneIdentifier)

        XCTAssertEqual(summary.eveningDarkStart, darkStart)
        XCTAssertEqual(summary.morningDarkEnd, darkEnd)
        XCTAssertEqual(summary.darkRangeText, "00:45 〜 04:45")
    }

    // MARK: - 白夜の天気カバレッジ

    /// 暗時間がない夜（白夜）でも、市民薄明後の時間帯の予報が揃っていれば天気データを利用可能とみなす。
    func test_hasUsableWeatherData_whiteNightUsesCivilNightHours() {
        let timeZoneIdentifier = "Europe/London"
        let start = makeDate(2026, 6, 21, 12, 0, timeZoneIdentifier: timeZoneIdentifier)
        let civilStart = makeDate(2026, 6, 21, 22, 15, timeZoneIdentifier: timeZoneIdentifier)
        let civilEnd = makeDate(2026, 6, 22, 3, 45, timeZoneIdentifier: timeZoneIdentifier)
        let events = (0..<96).map { step -> AstroEvent in
            let date = start.addingTimeInterval(Double(step) * 15 * 60)
            let isCivilNight = date >= civilStart && date < civilEnd
            return makeEvent(date: date, sunAltitude: isCivilNight ? -10 : 5)
        }
        let summary = makeSummary(events: events, timeZoneIdentifier: timeZoneIdentifier)
        XCTAssertEqual(summary.totalDarkHours, 0)

        // 23:00〜03:00 の正時（太陽高度 < -6° の正時サンプル）
        let fullHours = [23, 0, 1, 2, 3].map { hour in
            makeWeatherHour(date: makeDate(2026, 6, hour == 23 ? 21 : 22, hour, 0, timeZoneIdentifier: timeZoneIdentifier))
        }
        let referenceDate = makeDate(2026, 6, 10, 12, 0, timeZoneIdentifier: timeZoneIdentifier)
        XCTAssertTrue(summary.hasUsableWeatherData(nighttimeHours: fullHours, referenceDate: referenceDate))
        // 暗時間がないため観測可能時間帯の文字列は天文学的表示に任せる
        XCTAssertNil(summary.weatherAwareRangeText(nighttimeHours: fullHours, referenceDate: referenceDate))

        let partialHours = Array(fullHours.prefix(2))
        XCTAssertFalse(summary.hasUsableWeatherData(nighttimeHours: partialHours, referenceDate: referenceDate))
    }

    // MARK: - 惑星の可視判定

    /// 空が暗い時間帯のサンプルがない場合（白夜など）は高度に関わらず観測不可。
    func test_planetNightSummary_isNotVisibleWithoutDarkSky() {
        let summary = PlanetNightSummary(
            name: "金星",
            riseTime: nil,
            transitTime: nil,
            setTime: nil,
            peakAltitude: 40,
            magnitude: -4.0,
            hasDarkSkySamples: false
        )
        XCTAssertFalse(summary.isVisibleTonight)
        XCTAssertEqual(summary.observationDifficulty, .telescope)
    }

    // MARK: - 流星群の極大までの日数

    /// うるう年の 2/29 をまたぐ場合も実際の暦日差で数える。
    func test_meteorShowerNext_countsLeapDay() throws {
        let timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let leapYearDate = makeDate(2028, 2, 20, 21, 0)
        let leap = try XCTUnwrap(MeteorShowerCatalog.next(after: leapYearDate, timeZone: timeZone))
        XCTAssertEqual(leap.shower.id, "lyrids")
        XCTAssertEqual(leap.daysUntilPeak, 62)

        let commonYearDate = makeDate(2027, 2, 20, 21, 0)
        let common = try XCTUnwrap(MeteorShowerCatalog.next(after: commonYearDate, timeZone: timeZone))
        XCTAssertEqual(common.shower.id, "lyrids")
        XCTAssertEqual(common.daysUntilPeak, 61)
    }

    /// 年末からは翌年の極大日までの日数を返す。
    func test_meteorShowerNext_wrapsToNextYear() throws {
        let timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = makeDate(2027, 12, 25, 21, 0)
        let next = try XCTUnwrap(MeteorShowerCatalog.next(after: date, timeZone: timeZone))
        XCTAssertEqual(next.shower.id, "quadrantids")
        XCTAssertEqual(next.daysUntilPeak, 10)
    }
}
