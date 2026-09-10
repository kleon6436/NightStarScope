import Foundation

// LanguageModelSession is availability-gated, so the cache uses Sendable type erasure across deployment targets.
struct PendingPrewarmedSession: Sendable {
    let context: ObservationAdvisorToolContext
    let modelKind: AssistantModelKind
    let session: any Sendable
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
extension ObservationAdvisorService {
    func makeSession(
        language: String,
        toolContext: ObservationAdvisorToolContext,
        resolution: AssistantModelResolution,
        consumesPendingSession: Bool = true
    ) -> LanguageModelSession {
        if consumesPendingSession,
           let pending = pendingPrewarmedSessions.removeValue(forKey: language),
           pending.context == toolContext,
           pending.modelKind == resolution.kind,
           let prewarmedSession = pending.session as? LanguageModelSession {
            return prewarmedSession
        }

        return modelRuntime.makeSession(
            resolution: resolution,
            tools: [UpcomingNightsTool(snapshots: toolContext.upcomingNights)],
            instructions: Self.systemPrompt(language: language)
        )
    }

    #if DEBUG
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
    #endif

    func makeStream(
        for input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        prompt: String,
        resolution: AssistantModelResolution,
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
                        toolContext: toolContext,
                        resolution: resolution
                    )
                    #if DEBUG
                    Task { @MainActor [weak self] in
                        await self?.logTokenUsage(prompt: prompt)
                    }
                    #endif
                    let options = AssistantGenerationOptions.adviceGenerationOptions()
                    let stream = makeResponseStream(
                        session: session,
                        prompt: prompt,
                        options: options,
                        resolution: resolution
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

    private func makeResponseStream(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        resolution: AssistantModelResolution
    ) -> LanguageModelSession.ResponseStream<StargazingAdvice> {
        if #available(macOS 27.0, iOS 27.0, *) {
            return session.streamResponse(
                to: prompt,
                generating: StargazingAdvice.self,
                options: options,
                contextOptions: AssistantGenerationOptions.contextOptions(for: resolution.kind)
            )
        }

        return session.streamResponse(
            to: prompt,
            generating: StargazingAdvice.self,
            includeSchemaInPrompt: true,
            options: options
        )
    }
}

@available(macOS 27.0, iOS 27.0, *)
extension ObservationAdvisorService {
    static func mapModernError(_ error: any Error) -> ObservationAdvisorServiceError {
        switch mapFoundationModelsError(error) {
        case .contextExceeded:
            return .contextExceeded
        case .guardrail:
            return .guardrailViolation
        case .other:
            return .generationFailed
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension ObservationAdvisorService {
    static func mapLegacyError(_ error: any Error) -> ObservationAdvisorServiceError {
        switch mapFoundationModelsError(error) {
        case .contextExceeded:
            return .contextExceeded
        case .guardrail:
            return .guardrailViolation
        case .other:
            return .generationFailed
        }
    }
}
#endif
