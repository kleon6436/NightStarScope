import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AdviceVerdict: String, CaseIterable, Equatable, Sendable, Identifiable {
    private static let logger = Logger(subsystem: "com.nightscope", category: "ObservationAdvisor")

    case excellent
    case good
    case fair
    case poor
    case bad

    var id: Self { self }

    init(modelValue: String) {
        let normalized = modelValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "excellent", "絶好":
            self = .excellent
        case "good", "良好":
            self = .good
        case "fair", "まずまず", "普通":
            self = .fair
        case "poor", "難しい", "不向き":
            self = .poor
        case "bad", "非推奨", "観測困難":
            self = .bad
        default:
            Self.logger.warning("Unknown observation advice verdict; falling back to fair")
            self = .fair
        }
    }

    init(tier: StarGazingIndex.Tier) {
        switch tier {
        case .excellent:
            self = .excellent
        case .good:
            self = .good
        case .fair:
            self = .fair
        case .poor:
            self = .poor
        case .bad:
            self = .bad
        }
    }

    var localizedTitle: String {
        L10n.tr(localizationKey)
    }

    fileprivate var localizationKey: String {
        switch self {
        case .excellent:
            "advice.verdict.excellent"
        case .good:
            "advice.verdict.good"
        case .fair:
            "advice.verdict.fair"
        case .poor:
            "advice.verdict.poor"
        case .bad:
            "advice.verdict.bad"
        }
    }
}

struct ObservationAdvisorAdvicePartial: Equatable, Sendable {
    let headline: String?
    let verdict: String?
    let bestWindow: String?
    let reasons: [String]?
    let tips: [String]?
    let alternatives: [String]?
    init(
        headline: String? = nil,
        verdict: String? = nil,
        bestWindow: String? = nil,
        reasons: [String]? = nil,
        tips: [String]? = nil,
        alternatives: [String]? = nil
    ) {
        self.headline = headline
        self.verdict = verdict
        self.bestWindow = bestWindow
        self.reasons = reasons
        self.tips = tips
        self.alternatives = alternatives
    }
}

struct ObservationAdvisorAdvice: Equatable, Sendable {
    let headline: String
    let verdict: AdviceVerdict
    let bestWindow: String
    let reasons: [String]
    let tips: [String]
    let alternatives: [String]

    init(
        headline: String,
        verdict: AdviceVerdict,
        bestWindow: String = "",
        reasons: [String] = [],
        tips: [String] = [],
        alternatives: [String] = []
    ) {
        self.headline = headline
        self.verdict = verdict
        self.bestWindow = bestWindow
        self.reasons = reasons
        self.tips = tips
        self.alternatives = alternatives
    }

    init(partial: ObservationAdvisorAdvicePartial) throws {
        guard let headline = partial.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headline.isEmpty,
              let verdict = partial.verdict?.trimmingCharacters(in: .whitespacesAndNewlines),
              !verdict.isEmpty else {
            throw ObservationAdvisorAdviceValidationError.missingRequiredField
        }

        self.init(
            headline: headline,
            verdict: AdviceVerdict(modelValue: verdict),
            bestWindow: partial.bestWindow?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            reasons: partial.reasons ?? [],
            tips: partial.tips ?? [],
            alternatives: partial.alternatives ?? []
        )
    }
}

extension ObservationAdvisorAdvicePartial {
    init(_ advice: ObservationAdvisorAdvice) {
        self.init(
            headline: advice.headline,
            verdict: advice.verdict.rawValue,
            bestWindow: advice.bestWindow,
            reasons: advice.reasons,
            tips: advice.tips,
            alternatives: advice.alternatives
        )
    }
}

enum ObservationAdvisorAdviceValidationError: LocalizedError, Sendable {
    case missingRequiredField

    var errorDescription: String? {
        String(localized: "advice.error.generation_failed")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A structured stargazing advice card. All generated text must use the requested language.")
struct StargazingAdvice: Equatable, Sendable {
    @Guide(description: "A concise headline of 20 characters or fewer describing tonight's observing conditions.")
    var headline: String

    @Guide(
        description: "An English verdict key. Use exactly one allowed key.",
        .anyOf(["excellent", "good", "fair", "poor", "bad"])
    )
    var verdict: String

    @Guide(description: "The best observing time window, such as '21:30-23:00'. Use an empty string when unavailable.")
    var bestWindow: String

    @Guide(description: "Evidence for the verdict. Each item must be 40 characters or fewer.", .count(2...4))
    var reasons: [String]

    @Guide(
        description: "Concrete tips on equipment, direction, targets, or dark adaptation; each 40 characters or fewer.",
        .count(1...4)
    )
    var tips: [String]

    @Guide(
        description: "Alternative dates or locations from the upcoming candidate list only; empty when unavailable.",
        .maximumCount(2)
    )
    var alternatives: [String]

}

@available(macOS 26.0, iOS 26.0, *)
extension ObservationAdvisorAdvicePartial {
    init(_ generated: StargazingAdvice.PartiallyGenerated) {
        self.init(
            headline: generated.headline,
            verdict: generated.verdict,
            bestWindow: generated.bestWindow,
            reasons: completedAdviceValues(generated.reasons),
            tips: completedAdviceValues(generated.tips),
            alternatives: completedAdviceValues(generated.alternatives)
        )
    }

    init(_ generated: StargazingAdvice) {
        self.init(
            headline: generated.headline,
            verdict: generated.verdict,
            bestWindow: generated.bestWindow,
            reasons: generated.reasons,
            tips: generated.tips,
            alternatives: generated.alternatives
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
private func completedAdviceValues(_ values: [String?]?) -> [String] {
    values?.prefix(while: { $0 != nil }).reduce(into: []) { result, value in
        if let value {
            result.append(value)
        }
    } ?? []
}
#endif
