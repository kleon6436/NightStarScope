import XCTest
import Combine
@testable import NightScope

@MainActor
final class ObservationAdvisorViewModelTests: XCTestCase {
    func test_generate_transitionsIdleToLoadingStreamingComplete() async {
        let service = MockObservationAdvisorService(
            streamFactory: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(samplePartial(headline: "今夜のまとめ"))
                    continuation.yield(
                        samplePartial(headline: "今夜のまとめ", reasons: ["雲が少ない", "透明度が良い"])
                    )
                    continuation.yield(
                        samplePartial(headline: "今夜のまとめ", reasons: ["雲が少ない", "透明度が良い"])
                    )
                    continuation.finish()
                }
            }
        )
        let viewModel = ObservationAdvisorViewModel(service: service)
        var states: [ObservationAdvisorViewModel.State] = []
        let cancellable = viewModel.$state.sink { states.append($0) }

        viewModel.generate(input: sampleInput)
        await waitForState(.complete(sampleAdvice), in: viewModel)

        XCTAssertEqual(viewModel.state, .complete(sampleAdvice))
        XCTAssertTrue(states.contains(.loading))
        XCTAssertTrue(states.contains {
            if case .streaming = $0 { return true }
            return false
        })
        cancellable.cancel()
    }

    func test_cancel_midStream_returnsToIdle() async {
        let service = MockObservationAdvisorService(
            streamFactory: { service in
                AsyncThrowingStream { continuation in
                    continuation.yield(samplePartial(headline: "今夜のまとめ"))
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        continuation.yield(
                            samplePartial(
                                headline: "今夜のまとめ",
                                reasons: ["良い条件です", "風が弱いです"]
                            )
                        )
                        continuation.finish()
                    }
                    continuation.onTermination = { termination in
                        guard case .cancelled = termination else { return }
                        Task { @MainActor in
                            service.cancelledCount += 1
                        }
                    }
                }
            }
        )
        let viewModel = ObservationAdvisorViewModel(service: service)

        viewModel.generate(input: sampleInput)
        await waitForStreamingState(in: viewModel)
        viewModel.cancel()
        await waitForState(.idle, in: viewModel)

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertGreaterThanOrEqual(service.cancelledCount, 1)
    }

    func test_unavailableService_setsUnavailableImmediately() {
        let viewModel = ObservationAdvisorViewModel(
            service: MockObservationAdvisorService(availability: .unavailable(.deviceNotEligible))
        )

        XCTAssertEqual(viewModel.state, .unavailable(.deviceNotEligible))
        viewModel.generate(input: sampleInput)
        XCTAssertEqual(viewModel.state, .unavailable(.deviceNotEligible))
    }

    func test_unavailableService_preservesEachAvailabilityReason() {
        let reasons: [ObservationAdvisorAvailability.Reason] = [
            .unsupportedOS,
            .deviceNotEligible,
            .modelNotReady,
            .appleIntelligenceOff,
            .unknown
        ]

        for reason in reasons {
            let viewModel = ObservationAdvisorViewModel(
                service: MockObservationAdvisorService(availability: .unavailable(reason))
            )

            XCTAssertEqual(viewModel.state, .unavailable(reason))
        }
    }

    func test_unsupportedOS_service_setsUnsupportedState() {
        let viewModel = ObservationAdvisorViewModel(
            service: MockObservationAdvisorService(availability: .unavailable(.unsupportedOS))
        )

        XCTAssertEqual(viewModel.state, .unavailable(.unsupportedOS))
    }

    func test_cardVisibility_hidesUnsupportedReasons() {
        XCTAssertFalse(
            ObservationAdvisorViewModel.shouldShowCard(for: .unavailable(.unsupportedOS))
        )
        XCTAssertFalse(
            ObservationAdvisorViewModel.shouldShowCard(for: .unavailable(.deviceNotEligible))
        )
        XCTAssertTrue(
            ObservationAdvisorViewModel.shouldShowCard(for: .unavailable(.modelNotReady))
        )
    }

    func test_contextExceeded_retriesOnceWithShortenedInput() async {
        let service = MockObservationAdvisorService(
            firstError: ObservationAdvisorServiceError.contextExceeded,
            streamFactory: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(samplePartial(headline: "短縮後のアドバイス"))
                    continuation.finish()
                }
            }
        )
        let viewModel = ObservationAdvisorViewModel(service: service)

        viewModel.generate(input: longRetryInput)
        await waitForState(.complete(shortenedAdvice), in: viewModel)

        XCTAssertEqual(service.generateCallCount, 2)
        XCTAssertEqual(service.inputs.last?.dateString, longRetryInput.dateString)
        XCTAssertEqual(service.inputs.last?.locationName, longRetryInput.locationName)
        XCTAssertTrue(service.inputs.last?.isRetryPrompt == true)
        XCTAssertNotEqual(service.inputs.first, service.inputs.last)
    }

    func test_contextExceededAfterRetry_showsDedicatedLocalizedError() async {
        let service = MockObservationAdvisorService(
            error: ObservationAdvisorServiceError.contextExceeded,
            firstError: ObservationAdvisorServiceError.contextExceeded
        )
        let viewModel = ObservationAdvisorViewModel(service: service)

        viewModel.generate(input: sampleInput)
        await waitForState(
            .error(String(localized: "advice.error.context_exceeded")),
            in: viewModel
        )

        XCTAssertEqual(service.generateCallCount, 2)
    }

    func test_missingRequiredFields_setsGenerationError() async {
        let service = MockObservationAdvisorService(
            streamFactory: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(ObservationAdvisorAdvicePartial(bestWindow: "22:00〜23:00"))
                    continuation.finish()
                }
            }
        )
        let viewModel = ObservationAdvisorViewModel(service: service)

        viewModel.generate(input: sampleInput)
        await waitForState(
            .error(String(localized: "advice.error.generation_failed")),
            in: viewModel
        )
    }

    func test_errorPropagation_setsErrorState() async {
        let viewModel = ObservationAdvisorViewModel(
            service: MockObservationAdvisorService(error: MockObservationAdvisorError.failed)
        )

        viewModel.generate(input: sampleInput)
        await waitForState(
            .error(MockObservationAdvisorError.failed.localizedDescription),
            in: viewModel
        )

        XCTAssertEqual(viewModel.state, .error(MockObservationAdvisorError.failed.localizedDescription))
    }

    private func waitForState(
        _ expected: ObservationAdvisorViewModel.State,
        in viewModel: ObservationAdvisorViewModel,
        timeout: TimeInterval = 1.0
    ) async {
        let expectation = expectation(description: "state becomes \(expected)")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$state.sink { state in
            guard state == expected else { return }
            expectation.fulfill()
            cancellable?.cancel()
        }

        await fulfillment(of: [expectation], timeout: timeout)
        cancellable?.cancel()
    }

    private func waitForStreamingState(
        in viewModel: ObservationAdvisorViewModel,
        timeout: TimeInterval = 1.0
    ) async {
        let expectation = expectation(description: "state becomes streaming")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$state.sink { state in
            guard case .streaming = state else { return }
            expectation.fulfill()
            cancellable?.cancel()
        }

        await fulfillment(of: [expectation], timeout: timeout)
        cancellable?.cancel()
    }
}

private func samplePartial(
    headline: String = "今夜のまとめ",
    reasons: [String]? = ["雲が少ない", "透明度が良い"]
) -> ObservationAdvisorAdvicePartial {
    ObservationAdvisorAdvicePartial(
        headline: headline,
        verdict: "excellent",
        bestWindow: "22:15〜03:30",
        reasons: reasons,
        tips: ["暗順応を待つ"]
    )
}

private let sampleInput = ObservationAdvisorInput(
    language: "ja",
    isUnfavorable: false,
    dateString: "2026年5月13日（水）",
    locationName: "長野県 乗鞍高原",
    tierLabel: "良好",
    viewingWindowSummary: "22:15〜03:30（5時間15分）、見頃：00:45ごろ",
    moonSummary: "上弦の月（照度32%、23:10に沈む）",
    weatherSummary: "薄曇り、雲量35%、透明度良好、風速2m/s",
    lightPollutionSummary: "郊外の空（天の川は肉眼でうっすら見える）"
)

private let sampleAdvice = ObservationAdvisorAdvice(
    headline: "今夜のまとめ",
    verdict: .excellent,
    bestWindow: "22:15〜03:30",
    reasons: ["雲が少ない", "透明度が良い"],
    tips: ["暗順応を待つ"]
)

private let shortenedAdvice = ObservationAdvisorAdvice(
    headline: "短縮後のアドバイス",
    verdict: .excellent,
    bestWindow: "22:15〜03:30",
    reasons: ["雲が少ない", "透明度が良い"],
    tips: ["暗順応を待つ"]
)

private let longRetryInput = ObservationAdvisorInput(
    language: "ja",
    isUnfavorable: false,
    dateString: sampleInput.dateString,
    locationName: sampleInput.locationName,
    tierLabel: sampleInput.tierLabel,
    viewingWindowSummary: "22時15分から03時30分まで観測可能で、"
        + "後半まで安定して観測しやすい時間帯です。追加の説明です。",
    moonSummary: "上弦の月が夜空を照らし、"
        + "時間の経過とともに月明かりの影響が変化するため、"
        + "暗い天体の見え方にも注意が必要です。",
    weatherSummary: "薄曇りの時間帯があり、"
        + "雲の切れ間と透明度の変化、風の強まりを確認しながら"
        + "観測する必要があります。",
    lightPollutionSummary: "郊外の空ですが、"
        + "周辺の明かりが視界に入る方向では暗い天体の見え方に影響する"
        + "可能性があります。"
)

@MainActor
private final class MockObservationAdvisorService: ObservationAdvising {
    var availability: ObservationAdvisorAvailability
    var error: (any Error & Sendable)?
    var firstError: (any Error & Sendable)?
    var cancelledCount = 0
    var generateCallCount = 0
    var inputs: [ObservationAdvisorInput] = []
    var streamFactory: @MainActor (MockObservationAdvisorService)
        -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> = { _ in
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    init(
        availability: ObservationAdvisorAvailability = .available,
        error: (any Error & Sendable)? = nil,
        firstError: (any Error & Sendable)? = nil,
        streamFactory: @escaping @MainActor (MockObservationAdvisorService)
            -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> = { _ in
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    ) {
        self.availability = availability
        self.error = error
        self.firstError = firstError
        self.streamFactory = streamFactory
    }

    func generateAdvice(
        for input: ObservationAdvisorInput
    ) async throws -> AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error> {
        generateCallCount += 1
        inputs.append(input)
        if generateCallCount == 1, let firstError {
            throw firstError
        }
        if let error {
            throw error
        }
        return streamFactory(self)
    }

    func prewarm() {}
}

private enum MockObservationAdvisorError: LocalizedError, Sendable {
    case failed

    var errorDescription: String? {
        "生成に失敗しました。"
    }
}
