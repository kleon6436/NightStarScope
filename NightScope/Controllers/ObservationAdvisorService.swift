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
        for input: ObservationAdvisorInput
    ) async throws -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error>
    func prewarm()
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
    private static let logger = Logger(subsystem: "com.nightscope", category: "ObservationAdvisor")
    // LanguageModelSession is availability-gated, so stored cross-deployment state uses Sendable type erasure.
    private var pendingPrewarmedSessions: [String: any Sendable] = [:]

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
        for input: ObservationAdvisorInput
    ) async throws -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> {
        guard case .available = availability else {
            throw ObservationAdvisorServiceError.unavailable
        }

        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            return makeStream(
                for: input,
                prompt: makePrompt(for: input),
                mapError: Self.mapModernError
            )
        }
        if #available(macOS 26.0, iOS 26.0, *) {
            return makeStream(
                for: input,
                prompt: makePrompt(for: input),
                mapError: Self.mapLegacyError
            )
        }
        #endif

        throw ObservationAdvisorServiceError.unavailable
    }

    func prewarm() {
        guard case .available = availability else { return }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let language = Locale.current.language.languageCode?.identifier == "en" ? "en" : "ja"
            guard pendingPrewarmedSessions[language] == nil else { return }

            let session = makeSession(language: language, consumesPendingSession: false)
            session.prewarm()
            pendingPrewarmedSessions[language] = session
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
                + "別日・別地点の提案はしないこと。"
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
                + "Do not suggest other dates or locations."
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

    private static func systemPrompt(language: String) -> String {
        if language == "en" {
            return """
            You are a stargazing guide.
            All following data is precomputed. Explain it for beginners and return the structured StargazingAdvice card.

            Output contract (strictly follow):
            - Write every field in English.
            - headline is a concise heading of 20 characters or fewer.
            - verdict must be exactly one of: excellent, good, fair, poor, bad.
            - bestWindow is the useful observing window, or an empty string when unavailable.
            - reasons contains 2 to 4 evidence items, each 40 characters or fewer.
            - tips contains 1 to 4 concrete tips, each 40 characters or fewer.
            - Do not perform any new calculations, predictions, or evaluations
            - Do not estimate weather or celestial positions
            - You may quote numeric values from the input as evidence; do not invent values.
            - For poor conditions, explain the reasons specifically and honestly.
            - Do not suggest other dates or locations.
            - Concrete tips may cover direction, a target, equipment, and dark adaptation.
            - Do not suggest unsupported actions such as indoor observing or an unlisted location or date.
            - Stargazing assumes outdoor observation
            """
        }

        return """
        あなたは星空観察の案内人です。
        以下のデータはすべて事前に計算済みです。初心者向けの構造化された
        StargazingAdviceカードを返してください。

        出力契約（厳守）:
        - すべてのフィールドを必ず日本語で書くこと。
        - headlineは20文字以内の簡潔な見出しにすること。
        - verdictは英語キーexcellent、good、fair、poor、badのいずれか1つだけにすること。
        - bestWindowは観測に適した時間帯。不明なら空文字にすること。
        - reasonsは評価の根拠を2〜4個。各40文字以内にすること。
        - tipsは具体的な観測アドバイスを1〜4個。各40文字以内にすること。
        - 新たな計算・予測・評価を行わないこと
        - 気象予報・天体位置の推定を行わないこと
        - 入力に含まれる数値は根拠として引用してよいが、
          存在しない数値を作らないこと
        - 悪条件では理由を具体的かつ正直に説明し、別日・別地点は提案しないこと
        - tipsでは方角、観測ターゲット、持ち物、暗順応など具体的な助言を述べてよい
        - 入力にない室内観測、未掲載の場所や別日などは提案しないこと
        - 星空観察は屋外での観察が前提であり、入力にない行動は提案しないこと
        """
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
private extension ObservationAdvisorService {
    func makeSession(language: String, consumesPendingSession: Bool = true) -> LanguageModelSession {
        if consumesPendingSession,
           let prewarmedSession = pendingPrewarmedSessions.removeValue(forKey: language) as? LanguageModelSession {
            return prewarmedSession
        }

        return LanguageModelSession(
            model: .default,
            instructions: Self.systemPrompt(language: language)
        )
    }

    func logTokenUsage(prompt: String) async {
        // contextSize is back-deployed to 26.0; only tokenCount(for:) requires 26.4.
        let contextSize = SystemLanguageModel.default.contextSize
        if #available(macOS 26.4, iOS 26.4, *) {
            do {
                let tokenCount = try await SystemLanguageModel.default.tokenCount(for: prompt)
                Self.logger.info(
                    "Prompt tokens=\(tokenCount, privacy: .public), contextSize=\(contextSize, privacy: .public)"
                )
                if Double(tokenCount) > Double(contextSize) * 0.8 {
                    Self.logger.warning("Prompt token usage exceeds 80 percent of context size")
                }
            } catch {
                Self.logger.error("Prompt token count unavailable: \(String(describing: error), privacy: .public)")
            }
        } else {
            // Note: Character count is a conservative estimate until tokenCount is available on the deployment OS.
            let estimatedTokenCount = prompt.count
            Self.logger.info(
                "Estimated prompt tokens=\(estimatedTokenCount, privacy: .public), contextSize=\(contextSize, privacy: .public)"
            )
            if Double(estimatedTokenCount) > Double(contextSize) * 0.8 {
                Self.logger.warning("Estimated prompt token usage exceeds 80 percent of context size")
            }
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private extension ObservationAdvisorService {
    func makeStream(
        for input: ObservationAdvisorInput,
        prompt: String,
        mapError: @escaping @MainActor @Sendable (any Error) -> ObservationAdvisorServiceError
    ) -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    guard let self else {
                        throw CancellationError()
                    }

                    let session = self.makeSession(language: input.language)
                    Task { @MainActor [weak self] in
                        await self?.logTokenUsage(prompt: prompt)
                    }
                    let stream = session.streamResponse(
                        to: prompt,
                        generating: StargazingAdvice.self,
                        includeSchemaInPrompt: true
                    )
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        // FoundationModels streams cumulative snapshots, not deltas.
                        continuation.yield(ObservationAdvisorAdvicePartial(snapshot.content))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
private extension ObservationAdvisorService {
    static func mapModernError(_ error: any Error) -> ObservationAdvisorServiceError {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return .contextExceeded
            case .guardrailViolation:
                return .guardrailViolation
            default:
                return .generationFailed
            }
        }

        if error is SystemLanguageModel.Error || error is LanguageModelSession.Error {
            return .generationFailed
        }

        if let error = error as? LanguageModelSession.GenerationError {
            return mapLegacyError(error)
        }

        Self.logger.error(
            "Unexpected observation advisor generation error: \(String(describing: error), privacy: .public)"
        )
        return .generationFailed
    }
}

@available(macOS 26.0, iOS 26.0, *)
private extension ObservationAdvisorService {
    static func mapLegacyError(_ error: any Error) -> ObservationAdvisorServiceError {
        guard let error = error as? LanguageModelSession.GenerationError else {
            Self.logger.error(
                "Unexpected observation advisor generation error: \(String(describing: error), privacy: .public)"
            )
            return .generationFailed
        }

        switch error {
        case .exceededContextWindowSize:
            return .contextExceeded
        case .guardrailViolation:
            return .guardrailViolation
        default:
            return .generationFailed
        }
    }
}
#endif
