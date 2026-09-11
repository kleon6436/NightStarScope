import Foundation
import Combine

@MainActor
final class ObservationAdvisorViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case unavailable(ObservationAdvisorAvailability.Reason)
        case loading
        case streaming(ObservationAdvisorAdvicePartial)
        case complete(ObservationAdvisorAdvice)
        case error(String)
    }

    @Published private(set) var state: State
    @Published private(set) var transientNotice: String?

    private let service: any ObservationAdvising
    private var generationTask: Task<Void, Never>?
    private var hasReportedPCCFallback = false
    private var hasRetriedGenerationFailure = false

    init(service: (any ObservationAdvising)? = nil) {
        let resolved = service ?? ObservationAdvisorService()
        self.service = resolved
        self.state = Self.state(for: resolved.availability)
        self.transientNotice = nil
    }

#if DEBUG
    static func preview(state: State) -> ObservationAdvisorViewModel {
        let viewModel = ObservationAdvisorViewModel()
        viewModel.state = state
        return viewModel
    }
#endif

    func resolveModel(language: String) async -> AssistantModelResolution {
        await service.resolveModel(language: language)
    }

    func prewarm(
        for toolContext: ObservationAdvisorToolContext,
        resolution: AssistantModelResolution = AssistantModelResolution(
            kind: .onDevice,
            fallbackReason: nil
        )
    ) async {
        await service.prewarm(for: toolContext, resolution: resolution)
        if let notice = service.consumeTransientNotice() {
            transientNotice = notice
        }
    }

    func dismissTransientNotice() {
        transientNotice = nil
    }

    func generate(
        input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        resolution: AssistantModelResolution = AssistantModelResolution(
            kind: .onDevice,
            fallbackReason: nil
        )
    ) {
        generationTask?.cancel()
        hasRetriedGenerationFailure = false
        state = .loading

        generationTask = Task {
            do {
                let finalPartial = try await generateWithContextRetry(
                    input: input,
                    toolContext: toolContext,
                    resolution: resolution
                )
                if let notice = service.consumeTransientNotice() {
                    transientNotice = notice
                }
                guard !Task.isCancelled else { return }
                state = try makeCompleteState(from: finalPartial, toolContext: toolContext)
            } catch is CancellationError {
                state = .idle
            } catch let error as ObservationAdvisorServiceError where error == .unavailable {
                state = Self.state(for: service.availability)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        state = Self.state(for: service.availability)
    }

    private func makeCompleteState(
        from partial: ObservationAdvisorAdvicePartial,
        toolContext: ObservationAdvisorToolContext
    ) throws -> State {
        let groundedPartial = partial.withGroundedAlternatives(using: toolContext)
        return .complete(try ObservationAdvisorAdvice(partial: groundedPartial))
    }

    private func generateWithContextRetry(
        input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        resolution: AssistantModelResolution
    ) async throws -> ObservationAdvisorAdvicePartial {
        do {
            return try await runGeneration(
                input: input,
                toolContext: toolContext,
                resolution: resolution
            )
        } catch let error as ObservationAdvisorServiceError {
            if error == .contextExceeded {
                // Retry once with a compact context after the model reports a context overflow.
                state = .loading
                let retryInput = input.shortenedForRetry()
                return try await runGeneration(
                    input: retryInput,
                    toolContext: toolContext,
                    resolution: resolution,
                    timeout: .seconds(20)
                )
            }

            guard resolution.kind == .privateCloud,
                  error == .generationFailed || error == .unavailable else {
                if resolution.kind == .onDevice,
                   error == .generationFailed,
                   !hasRetriedGenerationFailure {
                    hasRetriedGenerationFailure = true
                    state = .loading
                    try await Task.sleep(for: .milliseconds(700))
                    return try await runGeneration(
                        input: input,
                        toolContext: toolContext,
                        resolution: resolution
                    )
                }
                throw error
            }

            if !hasReportedPCCFallback {
                hasReportedPCCFallback = true
                transientNotice = String(localized: "advice.notice.pcc_generation_fallback")
            }
            let onDeviceResolution = AssistantModelResolution(kind: .onDevice, fallbackReason: nil)
            return try await runGeneration(
                input: input,
                toolContext: toolContext,
                resolution: onDeviceResolution
            )
        }
    }

    private func runGeneration(
        input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        resolution: AssistantModelResolution,
        timeout: Duration = .seconds(30)
    ) async throws -> ObservationAdvisorAdvicePartial {
        let stream = try await service.generateAdvice(
            for: input,
            toolContext: toolContext,
            resolution: resolution
        )
        return try await resolveWithTimeout(stream: stream, timeout: timeout)
    }

    // Consumes the stream on the main actor (Task inherits @MainActor from generate()).
    // The deadline is checked between snapshot emissions; cancellation covers a stalled stream.
    private func resolveWithTimeout(
        stream: AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error>,
        timeout: Duration = .seconds(30)
    ) async throws -> ObservationAdvisorAdvicePartial {
        let deadline = ContinuousClock.now + timeout
        var latest: ObservationAdvisorAdvicePartial?
        for try await partial in stream {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ObservationAdvisorTimeoutError() }
            latest = partial
            guard state != .streaming(partial) else { continue }
            state = .streaming(partial)
        }
        guard let latest else {
            throw ObservationAdvisorAdviceValidationError.missingRequiredField
        }
        return latest
    }

    static func shouldShowCard(for state: State) -> Bool {
        guard case .unavailable(let reason) = state else { return true }
        return reason != .deviceNotEligible && reason != .unsupportedOS
    }

    private static func state(for availability: ObservationAdvisorAvailability) -> State {
        switch availability {
        case .available:
            .idle
        case .unavailable(let reason):
            .unavailable(reason)
        }
    }
}

private extension ObservationAdvisorAdvicePartial {
    func withGroundedAlternatives(using toolContext: ObservationAdvisorToolContext) -> Self {
        Self(
            headline: headline,
            verdict: verdict,
            bestWindow: bestWindow,
            reasons: reasons,
            tips: tips,
            alternatives: toolContext.groundedAlternatives(from: alternatives)
        )
    }
}

private extension ObservationAdvisorInput {
    func shortenedForRetry() -> Self {
        Self(
            language: language,
            isUnfavorable: isUnfavorable,
            dateString: dateString,
            locationName: locationName,
            tierLabel: tierLabel,
            viewingWindowSummary: compactForRetry(viewingWindowSummary, maxLength: 80),
            moonSummary: compactForRetry(moonSummary, maxLength: 48),
            weatherSummary: compactForRetry(weatherSummary, maxLength: 48),
            lightPollutionSummary: "",
            isRetryPrompt: true
        )
    }

    private func compactForRetry(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }

        let prefix = String(value.prefix(maxLength))
        let boundaryCharacters: Set<Character> = ["。", ".", "！", "!", "？", "?", "、", ",", " "]
        guard let boundary = prefix.lastIndex(where: { boundaryCharacters.contains($0) }) else {
            return prefix
        }
        return String(prefix[...boundary])
    }
}

private struct ObservationAdvisorTimeoutError: LocalizedError {
    var errorDescription: String? {
        String(localized: "advice.error.timeout")
    }
}
