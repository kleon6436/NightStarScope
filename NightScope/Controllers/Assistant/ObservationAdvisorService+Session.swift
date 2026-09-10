import Foundation

// LanguageModelSession is availability-gated, so the cache uses Sendable type erasure across deployment targets.
struct PendingPrewarmedSession: Sendable {
    let context: ObservationAdvisorToolContext
    let session: any Sendable
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
extension ObservationAdvisorService {
    func makeSession(
        language: String,
        toolContext: ObservationAdvisorToolContext,
        consumesPendingSession: Bool = true
    ) -> LanguageModelSession {
        if consumesPendingSession,
           let pending = pendingPrewarmedSessions.removeValue(forKey: language),
           pending.context == toolContext,
           let prewarmedSession = pending.session as? LanguageModelSession {
            return prewarmedSession
        }

        return LanguageModelSession(
            model: .default,
            tools: [UpcomingNightsTool(snapshots: toolContext.upcomingNights)],
            instructions: Self.systemPrompt(language: language)
        )
    }

    func logTokenUsage(prompt: String) async {
        // This measures only the user prompt; instructions, tool schemas, and runtime tool results are not included.
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
            // Single-line: OSLogMessage string interpolation cannot be concatenated with `+`.
            // swiftlint:disable:next line_length
            Self.logger.info("Estimated prompt tokens=\(estimatedTokenCount, privacy: .public), contextSize=\(contextSize, privacy: .public)")
            if Double(estimatedTokenCount) > Double(contextSize) * 0.8 {
                Self.logger.warning("Estimated prompt token usage exceeds 80 percent of context size")
            }
        }
    }

    func makeStream(
        for input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        prompt: String,
        mapError: @escaping @MainActor @Sendable (any Error) -> ObservationAdvisorServiceError
    ) -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    guard let self else {
                        throw CancellationError()
                    }

                    let session = self.makeSession(
                        language: input.language,
                        toolContext: toolContext
                    )
                    Task { @MainActor [weak self] in
                        await self?.logTokenUsage(prompt: prompt)
                    }
                    let options: GenerationOptions = if #available(macOS 27.0, iOS 27.0, *) {
                        GenerationOptions(toolCallingMode: .allowed)
                    } else {
                        GenerationOptions()
                    }
                    let stream = session.streamResponse(
                        to: prompt,
                        generating: StargazingAdvice.self,
                        includeSchemaInPrompt: true,
                        options: options
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
extension ObservationAdvisorService {
    static func mapModernError(_ error: any Error) -> ObservationAdvisorServiceError {
        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            return mapModernError(toolCallError.underlyingError)
        }

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
extension ObservationAdvisorService {
    static func mapLegacyError(_ error: any Error) -> ObservationAdvisorServiceError {
        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            return mapLegacyError(toolCallError.underlyingError)
        }

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
