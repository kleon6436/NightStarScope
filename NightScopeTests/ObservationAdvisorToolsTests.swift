import XCTest
import CoreLocation
@testable import NightScope
#if canImport(FoundationModels)
import FoundationModels
#endif

final class ObservationAdvisorToolsTests: XCTestCase {
#if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    func test_upcomingNightsReturnsCandidatesAndSupportsEmptySnapshot() async throws {
        let candidate = UpcomingNightToolSnapshot(
            dateString: "2026-05-14",
            locationName: "乗鞍高原",
            tier: "良好"
        )
        let result = try await UpcomingNightsTool(snapshots: [candidate]).call(arguments: .init())
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.date, "2026-05-14")
        XCTAssertEqual(result.candidates.first?.tier, "良好")

        let empty = try await UpcomingNightsTool(snapshots: []).call(arguments: .init())
        XCTAssertTrue(empty.candidates.isEmpty)
    }
#endif

    func test_contextBuilderCreatesPrimitiveSnapshotAndUsesExistingUpcomingIndex() {
        let date = Date(timeIntervalSince1970: 0)
        guard let utc = TimeZone(identifier: "UTC") else {
            XCTFail("UTC time zone should be available")
            return
        }
        let summary = makeContextSummary(date: date)
        let index = makeContextIndex()

        let context = ObservationAdvisorToolContextBuilder.build(
            source: ObservationAdvisorToolContextBuilder.Source(
                upcomingNights: [summary],
                upcomingIndexes: [date: index],
                locationName: "Test location",
                timeZone: utc,
                localeIdentifier: "en_US"
            )
        )

        XCTAssertEqual(context.language, "en")
        XCTAssertEqual(context.upcomingNights.count, 1)
        XCTAssertEqual(context.upcomingNights.first?.tier, "Good")

        let japaneseContext = ObservationAdvisorToolContextBuilder.build(
            source: ObservationAdvisorToolContextBuilder.Source(
                upcomingNights: [summary],
                upcomingIndexes: [date: index],
                locationName: "テスト地点",
                timeZone: utc,
                localeIdentifier: "ja_JP"
            )
        )

        XCTAssertEqual(japaneseContext.language, "ja")
        XCTAssertEqual(japaneseContext.upcomingNights.first?.tier, "良好")
    }

    func test_toolContextAcceptsOnlyKnownAlternativeCandidates() {
        let context = ObservationAdvisorToolContext(
            language: "en",
            upcomingNights: [
                UpcomingNightToolSnapshot(
                    dateString: "2026-05-14",
                    locationName: "Test location",
                    tier: "Good"
                )
            ]
        )

        XCTAssertEqual(
            context.groundedAlternatives(from: ["2026-05-14 - Test location"]),
            ["2026-05-14 · Test location"]
        )
        XCTAssertTrue(context.groundedAlternatives(from: ["2026-05-15 - Other location"]).isEmpty)
    }

    private func makeContextSummary(date: Date) -> NightSummary {
        NightSummary(
            date: date,
            location: CLLocationCoordinate2D(latitude: 35, longitude: 135),
            events: [],
            viewingWindows: [
                ViewingWindow(
                    start: date,
                    end: date.addingTimeInterval(3_600),
                    peakTime: date.addingTimeInterval(1_800),
                    peakAltitude: 50,
                    peakAzimuth: 180
                )
            ],
            moonPhaseAtMidnight: 0.1,
            timeZoneIdentifier: "UTC"
        )
    }

    private func makeContextIndex() -> StarGazingIndex {
        StarGazingIndex(
            score: 80,
            milkyWayScore: 0,
            constellationScore: 0,
            weatherScore: 30,
            lightPollutionScore: 20,
            hasWeatherData: true,
            hasLightPollutionData: true
        )
    }
}
