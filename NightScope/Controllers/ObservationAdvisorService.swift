import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ObservationAdvisorAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        case unsupportedOS
        case deviceNotEligible
        case modelNotReady
        case appleIntelligenceOff
        case unknown
    }
}

@MainActor
protocol ObservationAdvising: Sendable {
    var availability: ObservationAdvisorAvailability { get }
    func generateAdvice(
        for input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext
    ) async throws -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error>
    func prewarm(for toolContext: ObservationAdvisorToolContext)
}

enum ObservationAdvisorServiceError: LocalizedError, Equatable, Sendable {
    case unavailable
    case contextExceeded
    case guardrailViolation
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "advice.error.unavailable")
        case .contextExceeded:
            String(localized: "advice.error.context_exceeded")
        case .guardrailViolation:
            String(localized: "advice.error.guardrail")
        case .generationFailed:
            String(localized: "advice.error.generation_failed")
        }
    }
}

@MainActor
final class ObservationAdvisorService: ObservationAdvising {
    static let logger = Logger(subsystem: "com.nightscope", category: "ObservationAdvisor")
    // LanguageModelSession is availability-gated, so stored cross-deployment state uses Sendable type erasure.
    var pendingPrewarmedSessions: [String: PendingPrewarmedSession] = [:]

    var availability: ObservationAdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let other):
                switch other {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                case .appleIntelligenceNotEnabled:
                    return .unavailable(.appleIntelligenceOff)
                @unknown default:
                    return .unavailable(.unknown)
                }
            }
        }
        #endif
        return .unavailable(.unsupportedOS)
    }

    func generateAdvice(
        for input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext
    ) async throws -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> {
        guard case .available = availability else {
            throw ObservationAdvisorServiceError.unavailable
        }

        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            return makeStream(
                for: input,
                toolContext: toolContext,
                prompt: makePrompt(for: input),
                mapError: { error in Self.mapModernError(error) }
            )
        }
        if #available(macOS 26.0, iOS 26.0, *) {
            return makeStream(
                for: input,
                toolContext: toolContext,
                prompt: makePrompt(for: input),
                mapError: { error in Self.mapLegacyError(error) }
            )
        }
        #endif

        throw ObservationAdvisorServiceError.unavailable
    }

    func prewarm(for toolContext: ObservationAdvisorToolContext) {
        guard case .available = availability else { return }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let language = toolContext.language
            if let pending = pendingPrewarmedSessions[language] {
                if pending.context == toolContext {
                    return
                }
                pendingPrewarmedSessions.removeValue(forKey: language)
            }

            let session = makeSession(
                language: language,
                toolContext: toolContext,
                consumesPendingSession: false
            )
            // Match the snapshot so the first generation can reuse this tool-bearing session safely.
            session.prewarm()
            pendingPrewarmedSessions[language] = PendingPrewarmedSession(
                context: toolContext,
                session: session
            )
            Self.logger.debug("Prewarmed observation advisor session")
        }
        #endif
    }

    private func makePrompt(for input: ObservationAdvisorInput) -> String {
        if input.language == "en" {
            return makeEnglishPrompt(for: input)
        }

        let tierInstruction = input.isUnfavorable
            ? "【出力指示】条件が悪い理由を説明すること。"
                + "upcoming_nights_lookupの候補からのみ代替案を選ぶこと。"
            : "【出力指示】条件の説明と、具体的な観測のポイントを述べること。"
        let retryInstruction = input.isRetryPrompt
            ? "【追加指示】入力を簡潔に要約し、短い文章で出力すること。"
            : ""

        return """
        観測日: \(input.dateString)
        観測地: \(input.locationName)
        総合評価: \(input.tierLabel)
        \(tierInstruction)
        \(retryInstruction)
        見頃: \(input.viewingWindowSummary)
        月: \(input.moonSummary)
        天気: \(input.weatherSummary)
        光害: \(input.lightPollutionSummary)
        """
    }

    private func makeEnglishPrompt(for input: ObservationAdvisorInput) -> String {
        let tierInstruction = input.isUnfavorable
            ? "[Output instruction] Explain specifically why conditions are poor. "
                + "Choose alternatives only from upcoming_nights_lookup candidates."
            : "[Output instruction] Explain the conditions and provide concrete observing tips."
        let retryInstruction = input.isRetryPrompt
            ? "[Additional instruction] Summarize the input concisely and respond briefly."
            : ""

        return """
        Observation date: \(input.dateString)
        Location: \(input.locationName)
        Overall rating: \(input.tierLabel)
        \(tierInstruction)
        \(retryInstruction)
        Viewing window: \(input.viewingWindowSummary)
        Moon: \(input.moonSummary)
        Weather: \(input.weatherSummary)
        Light pollution: \(input.lightPollutionSummary)
        """
    }

    private static let englishPromptContract = """
    Output contract (strictly follow):
    - Write every field in English.
    - headline is a concise heading of 20 characters or fewer.
    - verdict must be exactly one of: excellent, good, fair, poor, bad.
    - bestWindow is the useful observing window, or an empty string when unavailable.
    - reasons contains 2 to 4 evidence items, each 40 characters or fewer.
    - tips contains 1 to 4 concrete tips, each 40 characters or fewer.
    - alternatives contains at most 2 candidates returned by upcoming_nights_lookup, or is empty.
    - For poor or unfavorable conditions, call upcoming_nights_lookup and choose alternatives only
      from its returned candidates. If there are no candidates, return an empty array.
    - Never invent a date or location, and do not suggest dates or locations outside the candidates.
    - Do not perform any new calculations, predictions, or evaluations.
    - Do not estimate weather or celestial positions.
    - You may quote numeric values from the precomputed data as evidence; do not invent values.
    - For poor conditions, explain the reasons specifically and honestly.
    - Concrete tips may cover direction, a target, equipment, and dark adaptation.
    - Do not suggest unsupported actions such as indoor observing.
    - Stargazing assumes outdoor observation.
    """

    private static let japanesePromptContract = """
    出力契約（厳守）:
    - すべてのフィールドを必ず日本語で書くこと。
    - headlineは20文字以内の簡潔な見出しにすること。
    - verdictは英語キーexcellent、good、fair、poor、badのいずれか1つだけにすること。
    - bestWindowは観測に適した時間帯。不明なら空文字にすること。
    - reasonsは評価の根拠を2〜4個。各40文字以内にすること。
    - tipsは具体的な観測アドバイスを1〜4個。各40文字以内にすること。
    - alternativesはupcoming_nights_lookupが返した候補から最大2個。
      候補がなければ空配列にすること。
    - 悪条件（不向き・観測困難）の場合のみupcoming_nights_lookupを呼び、
      返された候補からのみalternativesを選ぶこと。
    - ツールの候補にない日付や地名を決して作らないこと。
    - 新たな計算・予測・評価を行わないこと。
    - 気象予報・天体位置の推定を行わないこと。
    - 事前計算済みデータの数値は根拠として引用してよいが、
      存在しない数値を作らないこと。
    - 悪条件では理由を具体的かつ正直に説明すること。
    - tipsでは方角、観測ターゲット、持ち物、暗順応など具体的な助言を述べてよい。
    - 入力にない室内観測や未掲載の場所・別日などは提案しないこと。
    - 星空観察は屋外での観察が前提であること。
    """

    static func systemPrompt(language: String) -> String {
        if language == "en" {
            return """
            You are a stargazing guide.
            The following data is precomputed. Explain it for beginners and return the structured
            StargazingAdvice card.

            \(englishPromptContract)
            """
        }

        return """
        あなたは星空観察の案内人です。
        以下のデータはすべて事前に計算済みです。初心者向けの構造化された
        StargazingAdviceカードを返してください。

        \(japanesePromptContract)
        """
    }
}
