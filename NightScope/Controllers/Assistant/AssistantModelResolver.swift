import Foundation

enum AssistantModelKind: Equatable, Sendable {
    case onDevice
    case privateCloud
}

enum AssistantModelFallbackReason: Equatable, Sendable {
    case unsupportedOS
    case unavailable
    case unsupportedLocale
    case quotaLimitReached
}

enum AssistantPCCAvailability: Equatable, Sendable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case systemNotReady
    case unknown
}

enum AssistantPCCQuotaState: Equatable, Sendable {
    case unavailable
    case belowLimit(isApproachingLimit: Bool, resetDate: Date?)
    case limitReached(resetDate: Date?)
}

struct AssistantModelResolution: Equatable, Sendable {
    let kind: AssistantModelKind
    let fallbackReason: AssistantModelFallbackReason?
}

struct AssistantModelResolverInput: Equatable, Sendable {
    let highAccuracyEnabled: Bool
    let osSupportsPrivateCloud: Bool
    let pccAvailability: AssistantPCCAvailability
    let pccSupportsLocale: Bool
    let quotaState: AssistantPCCQuotaState
}

enum AssistantModelResolver {
    static func resolve(_ input: AssistantModelResolverInput) -> AssistantModelResolution {
        guard input.highAccuracyEnabled else {
            return AssistantModelResolution(kind: .onDevice, fallbackReason: nil)
        }

        guard input.osSupportsPrivateCloud else {
            return AssistantModelResolution(kind: .onDevice, fallbackReason: .unsupportedOS)
        }

        guard input.pccAvailability == .available else {
            return AssistantModelResolution(kind: .onDevice, fallbackReason: .unavailable)
        }

        guard input.pccSupportsLocale else {
            return AssistantModelResolution(kind: .onDevice, fallbackReason: .unsupportedLocale)
        }

        if case .limitReached = input.quotaState {
            return AssistantModelResolution(kind: .onDevice, fallbackReason: .quotaLimitReached)
        }

        return AssistantModelResolution(kind: .privateCloud, fallbackReason: nil)
    }
}
