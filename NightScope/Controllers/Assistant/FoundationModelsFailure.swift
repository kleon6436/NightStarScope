#if canImport(FoundationModels)
import FoundationModels

enum FoundationModelsFailure: Sendable {
    case contextExceeded
    case guardrail
    case other
}

@available(macOS 26.0, iOS 26.0, *)
func mapFoundationModelsError(_ error: any Error) -> FoundationModelsFailure {
    if let toolCallError = error as? LanguageModelSession.ToolCallError {
        return mapFoundationModelsError(toolCallError.underlyingError)
    }

    if #available(macOS 27.0, iOS 27.0, *),
       let failure = mapModernFoundationModelsError(error) {
        return failure
    }

    if let failure = mapLegacyFoundationModelsError(error) {
        return failure
    }

    return .other
}

@available(macOS 27.0, iOS 27.0, *)
private func mapModernFoundationModelsError(_ error: any Error) -> FoundationModelsFailure? {
    if error is PrivateCloudComputeLanguageModel.Error {
        return .other
    }

    guard let error = error as? LanguageModelError else { return nil }
    switch error {
    case .contextSizeExceeded:
        return .contextExceeded
    case .guardrailViolation:
        return .guardrail
    default:
        return .other
    }
}

@available(macOS 26.0, iOS 26.0, *)
private func mapLegacyFoundationModelsError(_ error: any Error) -> FoundationModelsFailure? {
    guard let error = error as? LanguageModelSession.GenerationError else { return nil }
    switch error {
    case .exceededContextWindowSize:
        return .contextExceeded
    case .guardrailViolation:
        return .guardrail
    default:
        return .other
    }
}
#endif
