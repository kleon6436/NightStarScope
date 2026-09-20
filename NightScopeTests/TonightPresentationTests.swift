import XCTest
import CoreLocation
@testable import NightScope

// MARK: - Fixtures

/// タイムゾーン依存の判定を検証するため、全フィクスチャを Asia/Tokyo 固定で組み立てる。
private let tokyoTimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

private func jst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    let calendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyoTimeZone)
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components) ?? Date()
}

private func makeHour(
    _ date: Date,
    cloudCover: Double,
    weatherCode: Int = 0,
    precipitation: Double = 0,
    temperature: Double = 15,
    dewpoint: Double = 2
) -> HourlyWeather {
    HourlyWeather(
        date: date,
        temperatureCelsius: temperature,
        cloudCoverPercent: cloudCover,
        precipitationMM: precipitation,
        windSpeedKmh: 5,
        humidityPercent: 50,
        dewpointCelsius: dewpoint,
        weatherCode: weatherCode,
        visibilityMeters: 20_000,
        windGustsKmh: nil,
        windSpeedKmh500hpa: nil
    )
}

/// 18:00〜翌 06:00 を 15 分刻みでサンプリングした 1 夜分のフィクスチャ。
/// `darkStartHour`〜`darkEndHour` の間だけ天文薄明が終わっている状態にする。
private func makeTokyoNight(
    date: Date = jst(2026, 8, 12),
    darkStartHour: Int = 20,
    darkEndHour: Int = 4,
    moonPhase: Double = 0.02,
    moonAltitude: Double = -10,
    window: (startHour: Int, endHour: Int, peakHour: Int)? = (22, 26, 24)
) -> NightSummary {
    let eveningStart = date.addingTimeInterval(18 * 3600)
    let sampleCount = 12 * 4  // 12 時間 × 15 分刻み
    let darkStart = date.addingTimeInterval(TimeInterval(darkStartHour) * 3600)
    let darkEnd = date.addingTimeInterval(TimeInterval(darkEndHour + 24) * 3600)

    let events: [AstroEvent] = (0..<sampleCount).map { step in
        let eventDate = eveningStart.addingTimeInterval(TimeInterval(step) * 900)
        let isDark = eventDate >= darkStart && eventDate < darkEnd
        return AstroEvent(
            date: eventDate,
            galacticCenterAltitude: 28,
            galacticCenterAzimuth: 190,
            sunAltitude: isDark ? -22 : -5,
            moonAltitude: moonAltitude,
            moonPhase: moonPhase
        )
    }

    let windows: [ViewingWindow] = window.map { spec in
        [
            ViewingWindow(
                start: date.addingTimeInterval(TimeInterval(spec.startHour) * 3600),
                end: date.addingTimeInterval(TimeInterval(spec.endHour) * 3600),
                peakTime: date.addingTimeInterval(TimeInterval(spec.peakHour) * 3600),
                peakAltitude: 32,
                peakAzimuth: 180
            )
        ]
    } ?? []

    return NightSummary(
        date: date,
        location: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
        events: events,
        viewingWindows: windows,
        moonPhaseAtMidnight: moonPhase,
        timeZoneIdentifier: tokyoTimeZone.identifier
    )
}

/// 暗夜 8 時間（20:00〜04:00）を隙間なく覆う 1 時間ごとの予報。
private func makeCoveringWeather(
    date: Date = jst(2026, 8, 12),
    cloudCover: Double = 5,
    cloudyHours: Set<Int> = [],
    cloudyCloudCover: Double = 90
) -> DayWeatherSummary {
    let hours = (20...27).map { hour -> HourlyWeather in
        let isCloudy = cloudyHours.contains(hour % 24)
        return makeHour(
            date.addingTimeInterval(TimeInterval(hour) * 3600),
            cloudCover: isCloudy ? cloudyCloudCover : cloudCover
        )
    }
    return DayWeatherSummary(date: date, nighttimeHours: hours)
}

private func makeIndex(score: Int) -> StarGazingIndex {
    StarGazingIndex(
        score: score,
        milkyWayScore: 0,
        constellationScore: 0,
        weatherScore: 0,
        lightPollutionScore: 0,
        hasWeatherData: true,
        hasLightPollutionData: true
    )
}

// MARK: - NightVerdictPresentation

final class TonightPresentationTests: XCTestCase {
    private func makeVerdict(
        score: Int?,
        summary: NightSummary = makeTokyoNight(),
        weather: DayWeatherSummary? = nil,
        hasReliableWeather: Bool = false
    ) -> NightVerdictPresentation {
        NightVerdictPresentation(
            index: score.map(makeIndex(score:)),
            summary: summary,
            weather: weather,
            hasReliableWeather: hasReliableWeather
        )
    }

    func test_headline_perTier() {
        XCTAssertEqual(makeVerdict(score: 95).headline, L10n.tr("絶好の星空日和"))
        XCTAssertEqual(makeVerdict(score: 80).headline, L10n.tr("今夜は星見向き"))
        XCTAssertEqual(makeVerdict(score: 60).headline, L10n.tr("条件はまずまず"))
        XCTAssertEqual(makeVerdict(score: 40).headline, L10n.tr("今夜はやや不向き"))
        XCTAssertEqual(makeVerdict(score: 10).headline, L10n.tr("今夜は星見に不向き"))
    }

    func test_headline_missingIndex_showsCalculating() {
        let verdict = makeVerdict(score: nil)
        XCTAssertEqual(verdict.headline, L10n.tr("計算中"))
        XCTAssertEqual(verdict.tierChipText, "")
    }

    func test_tierChipText_usesIndexLabel() {
        XCTAssertEqual(makeVerdict(score: 95).tierChipText, makeIndex(score: 95).label)
        XCTAssertEqual(makeVerdict(score: 40).tierChipText, makeIndex(score: 40).label)
    }

    func test_reason_rainWithBrightMoonAndHighDew_keepsTwoHighestPriorityClauses() {
        let rainyHour = makeHour(
            jst(2026, 8, 12, 22),
            cloudCover: 95,
            weatherCode: 63,
            precipitation: 2.0,
            temperature: 15,
            dewpoint: 14.5   // 気温との差 0.5℃ → 結露リスク高
        )
        let weather = DayWeatherSummary(date: jst(2026, 8, 12), nighttimeHours: [rainyHour])
        let verdict = makeVerdict(
            score: 20,
            summary: makeTokyoNight(moonPhase: 0.5),
            weather: weather,
            hasReliableWeather: true
        )

        XCTAssertEqual(weather.dewRiskLevel, .high)
        let clauses = verdict.reason.components(separatedBy: L10n.tr("reason.separator"))
        XCTAssertEqual(clauses.count, 2, "節は最大 2 つに制限される")
        XCTAssertEqual(clauses.first, L10n.format("%@で雲量%@", L10n.tr("雨"), L10n.percent(95)))
        XCTAssertEqual(clauses.last, L10n.tr("明るい月明かりあり"))
        XCTAssertFalse(verdict.reason.contains(L10n.tr("結露リスク高")), "優先度の低い結露は切り捨てる")
    }

    func test_reason_clearSkyWithNewMoonAndGoodTier_mentionsNoMoonlight() {
        let weather = makeCoveringWeather(cloudCover: 5)
        let verdict = makeVerdict(
            score: 80,
            summary: makeTokyoNight(moonPhase: 0.02),
            weather: weather,
            hasReliableWeather: true
        )

        XCTAssertEqual(
            verdict.reason,
            L10n.format("%@・雲量%@", L10n.tr("快晴"), L10n.percent(5))
                + L10n.tr("reason.separator")
                + L10n.tr("月明かりはほぼなし")
        )
    }

    func test_reason_unreliableWeather_reportsMissingData() {
        let verdict = makeVerdict(
            score: 60,
            summary: makeTokyoNight(moonPhase: 0.25),   // illumination 0.5 → 月の言及なし
            weather: makeCoveringWeather(),
            hasReliableWeather: false
        )

        XCTAssertEqual(verdict.reason, L10n.tr("天気データなし"))
    }

    // MARK: - NightTimelineModel

    private let timelineDate = jst(2026, 8, 12)

    private func makeTimeline(
        summary: NightSummary? = nil,
        nighttimeHours: [HourlyWeather] = []
    ) -> NightTimelineModel {
        NightTimelineModel(
            summary: summary ?? makeTokyoNight(date: timelineDate),
            nighttimeHours: nighttimeHours
        )
    }

    func test_axis_spansEveningSixToNextMorningSix() {
        let timeline = makeTimeline()
        XCTAssertEqual(timeline.axisStart, jst(2026, 8, 12, 18))
        XCTAssertEqual(timeline.axisEnd, jst(2026, 8, 13, 6))
        XCTAssertEqual(timeline.totalSeconds, 12 * 3600, accuracy: 0.001)
    }

    func test_fraction_mapsAndClamps() {
        let timeline = makeTimeline()
        XCTAssertEqual(timeline.fraction(of: jst(2026, 8, 12, 21)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(timeline.fraction(of: jst(2026, 8, 13, 0)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(timeline.fraction(of: jst(2026, 8, 12, 12)), 0, accuracy: 0.0001)
        XCTAssertEqual(timeline.fraction(of: jst(2026, 8, 13, 9)), 1, accuracy: 0.0001)
    }

    func test_darkSegmentAndTwilightSegments_areComplementary() throws {
        let timeline = makeTimeline()
        let dark = try XCTUnwrap(timeline.darkSegment)
        XCTAssertEqual(dark.startFraction, 2.0 / 12.0, accuracy: 0.0001)   // 20:00
        XCTAssertEqual(dark.endFraction, 10.0 / 12.0, accuracy: 0.0001)    // 04:00

        let twilight = timeline.twilightSegments
        XCTAssertEqual(twilight.count, 2)
        XCTAssertEqual(twilight[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(twilight[0].end, dark.startFraction, accuracy: 0.0001)
        XCTAssertEqual(twilight[1].start, dark.endFraction, accuracy: 0.0001)
        XCTAssertEqual(twilight[1].end, 1, accuracy: 0.0001)
    }

    func test_twilightSegments_coverWholeAxisWhenNoDarkHours() {
        let summary = NightSummary(
            date: timelineDate,
            location: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
            events: [],
            viewingWindows: [],
            moonPhaseAtMidnight: 0.02,
            timeZoneIdentifier: tokyoTimeZone.identifier
        )
        let timeline = makeTimeline(summary: summary)

        XCTAssertNil(timeline.darkSegment)
        XCTAssertEqual(timeline.twilightSegments.count, 1)
        XCTAssertEqual(timeline.twilightSegments[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(timeline.twilightSegments[0].end, 1, accuracy: 0.0001)
        XCTAssertNil(timeline.darkRangeText)
    }

    func test_milkyWaySegment_usesBestViewingWindow() throws {
        let timeline = makeTimeline()
        let segment = try XCTUnwrap(timeline.milkyWaySegment)
        XCTAssertEqual(segment.start, 4.0 / 12.0, accuracy: 0.0001)   // 22:00
        XCTAssertEqual(segment.end, 8.0 / 12.0, accuracy: 0.0001)     // 翌 02:00
        XCTAssertEqual(segment.peak, 6.0 / 12.0, accuracy: 0.0001)    // 翌 00:00
    }

    func test_milkyWaySegment_isNilWithoutWindow() {
        let timeline = makeTimeline(summary: makeTokyoNight(date: timelineDate, window: nil))
        XCTAssertNil(timeline.milkyWaySegment)
    }

    func test_cloudSamples_keepOnlyHoursInsideAxisAndStaySorted() {
        let hours = [
            makeHour(jst(2026, 8, 13, 1), cloudCover: 40),
            makeHour(jst(2026, 8, 12, 17), cloudCover: 10),   // 軸より前
            makeHour(jst(2026, 8, 12, 22), cloudCover: 20),
            makeHour(jst(2026, 8, 13, 7), cloudCover: 60)     // 軸より後
        ]
        let samples = makeTimeline(nighttimeHours: hours).cloudSamples

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.cloudCoverPercent), [20, 40])
        XCTAssertEqual(samples[0].fraction, 4.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(samples[1].fraction, 7.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(samples[0].precipitationMM, 0, accuracy: 0.0001)
    }

    func test_tickLabels_areEveryThreeHours() {
        let ticks = makeTimeline().tickLabels
        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(ticks.map(\.text), ["18:00", "21:00", "00:00", "03:00", "06:00"])
        XCTAssertEqual(ticks.first?.fraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(ticks.last?.fraction ?? -1, 1, accuracy: 0.0001)
    }

    func test_darkTexts_reflectSummary() {
        let timeline = makeTimeline()
        XCTAssertEqual(timeline.darkRangeText, "20:00 〜 04:00")
        XCTAssertEqual(timeline.darkHoursText, "\(L10n.number(8.0, fractionDigits: 1))h")
    }

    // MARK: - BestNightPicker

    private let referenceDate = jst(2026, 8, 1, 12)

    private typealias Night = (
        summary: NightSummary,
        index: StarGazingIndex?,
        weather: DayWeatherSummary?,
        isReliableWeather: Bool
    )

    private func night(
        day: Int,
        score: Int?,
        weather: DayWeatherSummary? = nil,
        isReliableWeather: Bool = true
    ) -> Night {
        let date = jst(2026, 8, day)
        return (
            makeTokyoNight(date: date),
            score.map(makeIndex(score:)),
            weather,
            isReliableWeather
        )
    }

    func test_pick_returnsNilWhenNoCandidates() {
        XCTAssertNil(BestNightPicker.pick(nights: [], referenceDate: referenceDate))
        XCTAssertNil(
            BestNightPicker.pick(
                nights: [night(day: 12, score: nil), night(day: 13, score: nil)],
                referenceDate: referenceDate
            )
        )
    }

    func test_pick_choosesHighestScoreAndSkipsUnscoredNights() throws {
        let nights = [
            night(day: 12, score: 40),
            night(day: 13, score: nil),
            night(day: 14, score: 85),
            night(day: 15, score: 60)
        ]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.index.score, 85)
        XCTAssertEqual(pick.summary.date, jst(2026, 8, 14))
    }

    func test_pick_breaksScoreTieByLongerObservableWindow() throws {
        let clearDate = jst(2026, 8, 14)
        let cloudyDate = jst(2026, 8, 13)
        let nights: [Night] = [
            (
                makeTokyoNight(date: cloudyDate),
                makeIndex(score: 70),
                makeCoveringWeather(date: cloudyDate, cloudyHours: [20, 21, 22, 23]),
                true
            ),
            (
                makeTokyoNight(date: clearDate),
                makeIndex(score: 70),
                makeCoveringWeather(date: clearDate),
                true
            )
        ]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.summary.date, clearDate, "同点なら観測可能時間が長い夜を選ぶ")
        XCTAssertEqual(pick.windowText, "20:00〜04:00")
    }

    func test_pick_breaksRemainingTieByEarlierDate() throws {
        let nights = [night(day: 15, score: 70), night(day: 13, score: 70)]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.summary.date, jst(2026, 8, 13))
        XCTAssertNil(pick.windowText, "天気が無ければ観測可能時間帯は算出できない")
    }

    func test_reasonText_includesCloudCoverOnlyWithReliableWeather() throws {
        let date = jst(2026, 8, 12)
        let weather = makeCoveringWeather(date: date, cloudCover: 5)
        let darkHours = L10n.number(8.0, fractionDigits: 1)

        let reliable = try XCTUnwrap(
            BestNightPicker.pick(
                nights: [(makeTokyoNight(date: date), makeIndex(score: 80), weather, true)],
                referenceDate: referenceDate
            )
        )
        XCTAssertEqual(reliable.reasonText, L10n.format("雲量%@・暗夜%@h", L10n.percent(5), darkHours))

        let unreliable = try XCTUnwrap(
            BestNightPicker.pick(
                nights: [(makeTokyoNight(date: date), makeIndex(score: 80), weather, false)],
                referenceDate: referenceDate
            )
        )
        XCTAssertEqual(unreliable.reasonText, L10n.format("暗夜%@h", darkHours))
    }

    func test_isWorthHighlighting_trueForFairOrBetter() throws {
        let nights = [night(day: 12, score: 50), night(day: 13, score: 49)]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.index.tier, .fair)
        XCTAssertTrue(pick.isWorthHighlighting)
    }

    func test_isWorthHighlighting_trueWhenPoorNightClearlyLeads() throws {
        let nights = [night(day: 12, score: 45), night(day: 13, score: 25)]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.index.tier, .poor)
        XCTAssertTrue(pick.isWorthHighlighting)
    }

    func test_isWorthHighlighting_falseWhenPoorNightsAreClose() throws {
        let nights = [night(day: 12, score: 45), night(day: 13, score: 40)]
        let pick = try XCTUnwrap(BestNightPicker.pick(nights: nights, referenceDate: referenceDate))

        XCTAssertEqual(pick.index.tier, .poor)
        XCTAssertFalse(pick.isWorthHighlighting)
    }

    // MARK: - ForecastCardPresentation

    func test_darkStartText_usesEveningDarkStartInGivenTimeZone() {
        let night = makeTokyoNight(date: jst(2026, 8, 12))
        let sut = ForecastCardPresentation(
            night: night,
            weather: nil,
            timeZone: night.timeZone,
            isReliableWeather: false,
            hasPartialWeather: false,
            isForecastOutOfRange: false,
            hasWeatherLoadError: false
        )

        XCTAssertEqual(sut.darkStartText, "20:00")
    }

    func test_darkStartText_isNilWithoutDarkHours() {
        let night = NightSummary.placeholder
        let sut = ForecastCardPresentation(
            night: night,
            weather: nil,
            timeZone: night.timeZone,
            isReliableWeather: false,
            hasPartialWeather: false,
            isForecastOutOfRange: false,
            hasWeatherLoadError: false
        )

        XCTAssertNil(sut.darkStartText)
    }
}
