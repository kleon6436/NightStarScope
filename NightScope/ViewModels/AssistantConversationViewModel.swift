import Foundation
import Combine

@MainActor
final class AssistantConversationViewModel: ObservableObject {
    private static let fallbackRenewalMessageCount = 8

    enum State: Equatable {
        case idle
        case streaming(String)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var messages: [AssistantConversationMessage] = []
    @Published private(set) var transientNotice: String?

    private let context: AssistantConversationContext
    private let factory: any AssistantConversationSessionFactory
    private var session: (any AssistantConversationSession)?
    private var generationTask: Task<Void, Never>?
    private var shouldRenewSession = false
    private var hasReportedFallback = false

    init(
        context: AssistantConversationContext,
        factory: (any AssistantConversationSessionFactory)? = nil
    ) {
        self.context = context
        self.factory = factory ?? makeDefaultAssistantConversationSessionFactory()
    }

    deinit {
        generationTask?.cancel()
    }

    func send(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, generationTask == nil else { return }

        messages.append(AssistantConversationMessage(role: .user, text: trimmedText))
        state = .streaming("")
        transientNotice = nil
        generationTask = Task { @MainActor [weak self] in
            await self?.generateResponse(to: trimmedText)
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        state = .idle
    }

    private func generateResponse(to text: String) async {
        defer { generationTask = nil }

        do {
            let activeSession = try await sessionForNextMessage()
            var latestText = ""
            var latestTokenCount: Int?
            for try await snapshot in activeSession.streamResponse(to: text) {
                try Task.checkCancellation()
                latestText = snapshot.text
                latestTokenCount = snapshot.totalTokenCount
                state = .streaming(latestText)
                if let tokenCount = latestTokenCount,
                   Double(tokenCount) >= Double(activeSession.contextSize) * 0.8 {
                    shouldRenewSession = true
                } else if latestTokenCount == nil,
                          messages.count + 1 >= Self.fallbackRenewalMessageCount {
                    // OS 26 does not expose per-response usage; bound transcript growth by turns.
                    shouldRenewSession = true
                }
            }

            guard !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantConversationError.generationFailed
            }
            messages.append(AssistantConversationMessage(role: .assistant, text: latestText))
            state = .idle
        } catch is CancellationError {
            state = .idle
        } catch let error as AssistantConversationError where error == .contextLimitReached {
            shouldRenewSession = true
            state = .error(error.localizedDescription)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func startNewConversation() {
        generationTask?.cancel()
        generationTask = nil
        session = nil
        shouldRenewSession = true
        messages.removeAll()
        transientNotice = nil
        state = .idle
    }

    private func sessionForNextMessage() async throws -> any AssistantConversationSession {
        if let session, !shouldRenewSession {
            return session
        }

        let initialContext = shouldRenewSession
            ? context.summary + "\nRecent conversation:\n" + recentConversation
            : context.summary
        let result = try await factory.makeSession(
            language: context.language,
            initialContext: initialContext
        )
        session = result.session
        shouldRenewSession = false
        if result.resolution.fallbackReason == .quotaLimitReached, !hasReportedFallback {
            hasReportedFallback = true
            transientNotice = String(localized: "advice.notice.pcc_fallback")
        }
        return result.session
    }

    private var recentConversation: String {
        messages
            .suffix(4)
            .map { "\($0.role.rawValue): \(String($0.text.prefix(180)))" }
            .joined(separator: "\n")
    }
}

enum AssistantConversationMessageRole: String, Sendable {
    case user
    case assistant
}

struct AssistantConversationMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: AssistantConversationMessageRole
    let text: String

    init(id: UUID = UUID(), role: AssistantConversationMessageRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
