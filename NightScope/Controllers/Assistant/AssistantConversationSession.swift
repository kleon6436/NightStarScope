import Foundation

struct AssistantConversationContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let language: String
    let headline: String
    let summary: String

    init(id: UUID = UUID(), language: String, headline: String = "", summary: String) {
        self.id = id
        self.language = language
        self.headline = headline
        self.summary = summary
    }

    init(advice: ObservationAdvisorAdvice, input: ObservationAdvisorInput) {
        self.init(
            language: input.language,
            headline: advice.headline,
            summary: Self.makeSummary(advice: advice, input: input)
        )
    }

    private static func makeSummary(
        advice: ObservationAdvisorAdvice,
        input: ObservationAdvisorInput
    ) -> String {
        let lines = [
            line("headline", advice.headline),
            line("verdict", advice.verdict.rawValue),
            line("best window", advice.bestWindow),
            line("reasons", advice.reasons.joined(separator: " / "), limit: 180),
            line("tips", advice.tips.joined(separator: " / "), limit: 180),
            line("alternatives", advice.alternatives.joined(separator: " / "), limit: 180),
            line("date", input.dateString, limit: 32),
            line("location", input.locationName, limit: 90),
            line("overall tier", input.tierLabel, limit: 40),
            line("viewing", input.viewingWindowSummary, limit: 90),
            line("weather", input.weatherSummary, limit: 90),
            line("moon", input.moonSummary, limit: 90),
            line("light pollution", input.lightPollutionSummary, limit: 90)
        ]
        return lines.joined(separator: "\n")
    }

    private static func line(_ label: String, _ value: String, limit: Int = 90) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = String(compact.prefix(limit))
        return "\(label): \(shortened)"
    }
}

struct AssistantConversationStreamSnapshot: Sendable {
    let text: String
    let totalTokenCount: Int?
}

struct AssistantConversationSessionResult: Sendable {
    let session: any AssistantConversationSession
    let resolution: AssistantModelResolution
}

enum AssistantConversationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case generationFailed
    case contextLimitReached

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "advice.conversation.error.unavailable")
        case .generationFailed:
            String(localized: "advice.conversation.error")
        case .contextLimitReached:
            String(localized: "advice.conversation.error.context_limit")
        }
    }
}

@MainActor
protocol AssistantConversationSession: AnyObject, Sendable {
    var contextSize: Int { get }
    func streamResponse(to text: String) -> AsyncThrowingStream<AssistantConversationStreamSnapshot, Error>
}

@MainActor
protocol AssistantConversationSessionFactory: Sendable {
    func makeSession(
        language: String,
        initialContext: String,
        forceOnDevice: Bool
    ) async throws -> AssistantConversationSessionResult
}

@MainActor
private final class UnavailableConversationSessionFactory: AssistantConversationSessionFactory {
    func makeSession(
        language _: String,
        initialContext _: String,
        forceOnDevice _: Bool
    ) async throws -> AssistantConversationSessionResult {
        throw AssistantConversationError.unavailable
    }
}

#if canImport(FoundationModels)
import FoundationModels

@MainActor
final class FoundationConversationSessionFactory: AssistantConversationSessionFactory {
    private let modelRuntime: AssistantModelRuntime

    init(modelRuntime: AssistantModelRuntime? = nil) {
        self.modelRuntime = modelRuntime ?? AssistantModelRuntime()
    }

    func makeSession(
        language: String,
        initialContext: String,
        forceOnDevice: Bool
    ) async throws -> AssistantConversationSessionResult {
        let resolution = forceOnDevice
            ? AssistantModelResolution(kind: .onDevice, fallbackReason: nil)
            : await modelRuntime.resolve(language: language)
        guard resolution.kind == .privateCloud || isOnDeviceAvailable else {
            throw AssistantConversationError.unavailable
        }

        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw AssistantConversationError.unavailable
        }

        let instructions = Self.instructions(language: language, initialContext: initialContext)
        let session = modelRuntime.makeSession(resolution: resolution, tools: [], instructions: instructions)
        let contextSize = await modelRuntime.contextSize(for: resolution)
        return AssistantConversationSessionResult(
            session: FoundationModelsConversationSession(
                session: session,
                contextSize: contextSize,
                resolution: resolution
            ),
            resolution: resolution
        )
    }

    private var isOnDeviceAvailable: Bool {
        switch AssistantModelRuntime.onDeviceAvailability() {
        case .available:
            true
        case .unavailable:
            false
        }
    }

    private static func instructions(language: String, initialContext: String) -> String {
        let languageInstruction = language == "en"
            ? "Respond in English. Be concise, practical, and honest about the supplied data."
            : "必ず日本語で回答してください。提示されたデータに基づき、簡潔で具体的に答えてください。"
        return """
        You are NightScope's stargazing assistant.
        \(languageInstruction)
        This is the current observation context. Do not invent facts outside it:
        \(initialContext)
        """
    }
}

@available(macOS 26.0, iOS 26.0, *)
@MainActor
private final class FoundationModelsConversationSession: AssistantConversationSession {
    private let session: LanguageModelSession
    let contextSize: Int
    private let resolution: AssistantModelResolution

    init(
        session: LanguageModelSession,
        contextSize: Int,
        resolution: AssistantModelResolution
    ) {
        self.session = session
        self.contextSize = contextSize
        self.resolution = resolution
    }

    func streamResponse(to text: String) -> AsyncThrowingStream<AssistantConversationStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let stream: LanguageModelSession.ResponseStream<String>
                    if #available(macOS 27.0, iOS 27.0, *) {
                        stream = session.streamResponse(
                            to: text,
                            options: AssistantGenerationOptions.conversationGenerationOptions(),
                            contextOptions: AssistantGenerationOptions.contextOptions(for: resolution.kind)
                        )
                    } else {
                        stream = session.streamResponse(
                            to: text,
                            options: AssistantGenerationOptions.conversationGenerationOptions()
                        )
                    }

                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        let tokenCount: Int? = if #available(macOS 27.0, iOS 27.0, *) {
                            snapshot.usage.totalTokenCount
                        } else {
                            nil
                        }
                        continuation.yield(
                            AssistantConversationStreamSnapshot(
                                text: snapshot.content,
                                totalTokenCount: tokenCount
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mapError(_ error: any Error) -> AssistantConversationError {
        switch mapFoundationModelsError(error) {
        case .contextExceeded:
            return .contextLimitReached
        case .guardrail, .other:
            return .generationFailed
        }
    }

}
#endif

@MainActor
func makeDefaultAssistantConversationSessionFactory() -> any AssistantConversationSessionFactory {
    #if canImport(FoundationModels)
    FoundationConversationSessionFactory()
#else
    UnavailableConversationSessionFactory()
    #endif
}
