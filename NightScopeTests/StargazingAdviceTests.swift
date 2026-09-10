import XCTest
@testable import NightScope
#if canImport(FoundationModels)
import FoundationModels
#endif

final class StargazingAdviceTests: XCTestCase {
    func test_modelVerdictMapsToAppVerdict() {
        let values: [(String, AdviceVerdict)] = [
            ("excellent", .excellent),
            ("good", .good),
            ("fair", .fair),
            ("poor", .poor),
            ("bad", .bad)
        ]

        for (modelValue, expected) in values {
            XCTAssertEqual(AdviceVerdict(modelValue: modelValue), expected)
        }
    }

    func test_unknownModelVerdictFallsBackToFair() {
        XCTAssertEqual(AdviceVerdict(modelValue: "unexpected"), .fair)
    }

    func test_tierMapsToMatchingVerdict() {
        let values: [(StarGazingIndex.Tier, AdviceVerdict)] = [
            (.excellent, .excellent),
            (.good, .good),
            (.fair, .fair),
            (.poor, .poor),
            (.bad, .bad)
        ]

        for (tier, expected) in values {
            XCTAssertEqual(AdviceVerdict(tier: tier), expected)
        }
    }

    func test_completeAdviceRequiresHeadlineAndVerdict() {
        XCTAssertThrowsError(
            try ObservationAdvisorAdvice(
                partial: ObservationAdvisorAdvicePartial(
                    headline: " ",
                    verdict: "good"
                )
            )
        )
        XCTAssertThrowsError(
            try ObservationAdvisorAdvice(
                partial: ObservationAdvisorAdvicePartial(
                    headline: "見出し",
                    verdict: " "
                )
            )
        )
    }

    func test_sparseReasonsAreAccepted() throws {
        let advice = try ObservationAdvisorAdvice(
            partial: ObservationAdvisorAdvicePartial(
                headline: "観測日和",
                verdict: "excellent",
                bestWindow: "22:00〜23:00",
                reasons: [],
                tips: ["暗順応を待つ"]
            )
        )

        XCTAssertEqual(advice.reasons, [])

        let oneReason = try ObservationAdvisorAdvice(
            partial: ObservationAdvisorAdvicePartial(
                headline: "観測日和",
                verdict: "excellent",
                reasons: ["雲が少ない"],
                tips: ["暗順応を待つ"]
            )
        )

        XCTAssertEqual(oneReason.reasons, ["雲が少ない"])
        XCTAssertEqual(advice.tips.count, 1)
    }

    func test_adviceFieldsSupportGuideBoundaryCounts() throws {
        let advice = try ObservationAdvisorAdvice(
            partial: ObservationAdvisorAdvicePartial(
                headline: "観測計画",
                verdict: "good",
                reasons: ["理由1", "理由2", "理由3", "理由4"],
                tips: ["ヒント"]
            )
        )

        XCTAssertEqual(advice.reasons.count, 4)
        XCTAssertEqual(advice.tips.count, 1)
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    func test_generatedContentDecodesStargazingAdvice() throws {
        let content = try GeneratedContent(json: """
        {
          "headline": "Clear skies",
          "verdict": "excellent",
          "bestWindow": "22:00-23:00",
          "reasons": ["Few clouds", "Good transparency"],
          "tips": ["Wait for dark adaptation"]
        }
        """)
        let generated = try StargazingAdvice(content)
        let partial = ObservationAdvisorAdvicePartial(generated)
        let advice = try ObservationAdvisorAdvice(partial: partial)

        XCTAssertEqual(advice.headline, "Clear skies")
        XCTAssertEqual(advice.verdict, .excellent)
    }
#endif
}
