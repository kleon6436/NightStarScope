import XCTest
@testable import NightScope

@MainActor
final class AssistantConversationViewModelTests: XCTestCase {
    func test_sendStreamsResponseAndKeepsConversationHistory() async {
        let session = MockConversationSession(contextSize: 1000) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "答え", totalTokenCount: 20))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(session: session)
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        viewModel.send("どの方角を見れば？")
        await waitForIdle(with: viewModel)

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.messages.map(\.text), ["どの方角を見れば？", "答え"])
        XCTAssertEqual(session.sentTexts, ["どの方角を見れば？"])
    }

    func test_generationErrorIsExposed() async {
        let session = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: MockConversationError.failed)
            }
        }
        let viewModel = AssistantConversationViewModel(
            context: sampleContext,
            factory: MockConversationSessionFactory(session: session)
        )

        viewModel.send("明日はどう？")
        await waitForError(with: viewModel)

        XCTAssertEqual(viewModel.state, .error(MockConversationError.failed.localizedDescription))
    }

    func test_cancelStopsStreamingAndReturnsToIdle() async {
        let session = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "途中", totalTokenCount: 20))
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    continuation.yield(AssistantConversationStreamSnapshot(text: "完了", totalTokenCount: 30))
                    continuation.finish()
                }
            }
        }
        let viewModel = AssistantConversationViewModel(
            context: sampleContext,
            factory: MockConversationSessionFactory(session: session)
        )

        viewModel.send("機材のおすすめは？")
        await waitForStreaming(with: viewModel)
        viewModel.cancel()
        await Task.yield()

        XCTAssertEqual(viewModel.state, .idle)
    }

    func test_contextThresholdCreatesFreshSessionWithRecentContext() async {
        let firstSession = MockConversationSession(contextSize: 100) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "最初の答え", totalTokenCount: 80))
                continuation.finish()
            }
        }
        let secondSession = MockConversationSession(contextSize: 100) { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "次の答え", totalTokenCount: 20))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(sessions: [firstSession, secondSession])
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        viewModel.send("最初の質問")
        await waitForIdle(with: viewModel)
        viewModel.send("次の質問")
        await waitForIdle(with: viewModel)

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertTrue(factory.initialContexts[1].contains("最初の質問"))
        XCTAssertTrue(factory.initialContexts[1].contains("最初の答え"))
    }

    func test_os26WithoutUsageRenewsSessionAfterFourTurns() async {
        let firstSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "回答", totalTokenCount: nil))
                continuation.finish()
            }
        }
        let secondSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "新しい回答", totalTokenCount: nil))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(sessions: [firstSession, secondSession])
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        for index in 1...5 {
            viewModel.send("質問\(index)")
            await waitForIdle(with: viewModel)
        }

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(firstSession.sentTexts.count, 4)
        XCTAssertEqual(secondSession.sentTexts, ["質問5"])
    }

    func test_contextLimitErrorRenewsSessionOnNextSend() async {
        let firstSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: AssistantConversationError.contextLimitReached)
            }
        }
        let secondSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "復帰しました", totalTokenCount: nil))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(sessions: [firstSession, secondSession])
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        viewModel.send("長い質問")
        await waitForError(with: viewModel)
        viewModel.send("もう一度")
        await waitForIdle(with: viewModel)

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(viewModel.messages.last?.text, "復帰しました")
    }

    func test_startNewConversationClearsMessagesAndCreatesFreshSession() async {
        let firstSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "最初の回答", totalTokenCount: nil))
                continuation.finish()
            }
        }
        let secondSession = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "新しい回答", totalTokenCount: nil))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(sessions: [firstSession, secondSession])
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        viewModel.send("最初の質問")
        await waitForIdle(with: viewModel)
        viewModel.startNewConversation()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.send("新しい質問")
        await waitForIdle(with: viewModel)

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(viewModel.messages.map(\.text), ["新しい質問", "新しい回答"])
    }

    func test_quotaFallbackSetsTransientNotice() async {
        let session = MockConversationSession { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(AssistantConversationStreamSnapshot(text: "回答", totalTokenCount: 20))
                continuation.finish()
            }
        }
        let factory = MockConversationSessionFactory(
            session: session,
            resolution: AssistantModelResolution(kind: .onDevice, fallbackReason: .quotaLimitReached)
        )
        let viewModel = AssistantConversationViewModel(context: sampleContext, factory: factory)

        viewModel.send("質問")
        await waitForIdle(with: viewModel)

        XCTAssertEqual(viewModel.transientNotice, String(localized: "advice.notice.pcc_fallback"))
    }

    private func waitForIdle(with viewModel: AssistantConversationViewModel) async {
        for _ in 0..<100 {
            // A context-limit failure leaves an unanswered user message, so message
            // count is not always even; only the idle state is a reliable signal.
            if viewModel.state == .idle, viewModel.messages.last?.role == .assistant {
                return
            }
            await Task.yield()
        }
        XCTFail("Conversation did not become idle")
    }

    private func waitForStreaming(with viewModel: AssistantConversationViewModel) async {
        for _ in 0..<100 {
            if case .streaming = viewModel.state { return }
            await Task.yield()
        }
        XCTFail("Conversation did not start streaming")
    }

    private func waitForError(with viewModel: AssistantConversationViewModel) async {
        for _ in 0..<100 {
            if case .error = viewModel.state { return }
            await Task.yield()
        }
        XCTFail("Conversation did not enter error state")
    }
}

private let sampleContext = AssistantConversationContext(
    language: "ja",
    summary: "headline: 今夜のまとめ\nlocation: 長野県"
)

@MainActor
private final class MockConversationSessionFactory: AssistantConversationSessionFactory {
    private let sessions: [MockConversationSession]
    private let resolution: AssistantModelResolution
    private(set) var makeCount = 0
    private(set) var initialContexts: [String] = []

    init(
        session: MockConversationSession,
        resolution: AssistantModelResolution = AssistantModelResolution(kind: .onDevice, fallbackReason: nil)
    ) {
        self.sessions = [session]
        self.resolution = resolution
    }

    init(sessions: [MockConversationSession]) {
        self.sessions = sessions
        self.resolution = AssistantModelResolution(kind: .onDevice, fallbackReason: nil)
    }

    func makeSession(
        language _: String,
        initialContext: String
    ) async throws -> AssistantConversationSessionResult {
        let index = min(makeCount, sessions.count - 1)
        makeCount += 1
        initialContexts.append(initialContext)
        return AssistantConversationSessionResult(
            session: sessions[index],
            resolution: resolution
        )
    }
}

@MainActor
private final class MockConversationSession: AssistantConversationSession {
    let contextSize: Int
    private let streamFactory: @MainActor (String) -> AsyncThrowingStream<AssistantConversationStreamSnapshot, Error>
    private(set) var sentTexts: [String] = []

    init(
        contextSize: Int = 1000,
        streamFactory: @escaping @MainActor (String)
            -> AsyncThrowingStream<AssistantConversationStreamSnapshot, Error>
    ) {
        self.contextSize = contextSize
        self.streamFactory = streamFactory
    }

    func streamResponse(to text: String) -> AsyncThrowingStream<AssistantConversationStreamSnapshot, Error> {
        sentTexts.append(text)
        return streamFactory(text)
    }
}

private enum MockConversationError: LocalizedError, Sendable {
    case failed

    var errorDescription: String? { "会話に失敗しました。" }
}
