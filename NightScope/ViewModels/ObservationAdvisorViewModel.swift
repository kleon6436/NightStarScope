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

    private let service: any ObservationAdvising
    private var generationTask: Task<Void, Never>?

    init(service: (any ObservationAdvising)? = nil) {
        let resolved = service ?? ObservationAdvisorService()
        self.service = resolved
        self.state = Self.state(for: resolved.availability)
    }

#if DEBUG
    static func preview(state: State) -> ObservationAdvisorViewModel {
        let viewModel = ObservationAdvisorViewModel()
        viewModel.state = state
        return viewModel
    }
#endif

    func prewarm(for toolContext: ObservationAdvisorToolContext) {
        service.prewarm(for: toolContext)
    }

    func generate(
        input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext
    ) {
        guard case .available = service.availability else {
            generationTask?.cancel()
            generationTask = nil
            state = Self.state(for: service.availability)
            return
        }

        generationTask?.cancel()
        state = .loading

        generationTask = Task {
            do {
                let finalPartial = try await generateWithContextRetry(
                    input: input,
                    toolContext: toolContext
                )
                guard !Task.isCancelled else { return }
                state = try makeCompleteState(from: finalPartial, toolContext: toolContext)
            } catch is CancellationError {
                state = .idle
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
        toolContext: ObservationAdvisorToolContext
    ) async throws -> ObservationAdvisorAdvicePartial {
        do {
            let stream = try await service.generateAdvice(for: input, toolContext: toolContext)
            return try await resolveWithTimeout(stream: stream, toolContext: toolContext)
        } catch let error as ObservationAdvisorServiceError {
            guard error == .contextExceeded else { throw error }

            // Retry once with a compact context after the model reports a context overflow.
            state = .loading
            let retryInput = input.shortenedForRetry()
            let retryStream = try await service.generateAdvice(
                for: retryInput,
                toolContext: toolContext
            )
            return try await resolveWithTimeout(
                stream: retryStream,
                timeout: .seconds(20),
                toolContext: toolContext
            )
        }
    }

    // Consumes the stream on the main actor (Task inherits @MainActor from generate()).
    // The deadline is checked between snapshot emissions; cancellation covers a stalled stream.
    private func resolveWithTimeout(
        stream: AsyncThrowingStream<ObservationAdvisorAdvicePartial, Error>,
        timeout: Duration = .seconds(30),
        toolContext: ObservationAdvisorToolContext
    ) async throws -> ObservationAdvisorAdvicePartial {
        let deadline = ContinuousClock.now + timeout
        var latest: ObservationAdvisorAdvicePartial?
        for try await partial in stream {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ObservationAdvisorTimeoutError() }
            let groundedPartial = partial.withGroundedAlternatives(using: toolContext)
            latest = groundedPartial
            guard state != .streaming(groundedPartial) else { continue }
            state = .streaming(groundedPartial)
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
