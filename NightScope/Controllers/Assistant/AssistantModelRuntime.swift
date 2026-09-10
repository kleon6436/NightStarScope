import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AssistantModelRuntime {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func resolve(language: String) async -> AssistantModelResolution {
        let highAccuracyEnabled = userDefaults.bool(forKey: "assistantHighAccuracyMode")
        guard highAccuracyEnabled else {
            return AssistantModelResolver.resolve(
            AssistantModelResolverInput(
                    highAccuracyEnabled: false,
                    osSupportsPrivateCloud: false,
                    pccAvailability: .unsupportedOS,
                    pccSupportsLocale: false,
                    quotaState: .unavailable
                )
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            let availability = Self.mapAvailability(model.availability)
            let supportsLocale: Bool
            if availability == .available {
                supportsLocale = (try? await model.supportsLocale(Locale(identifier: language))) ?? false
            } else {
                supportsLocale = false
            }
            return AssistantModelResolver.resolve(
                AssistantModelResolverInput(
                    highAccuracyEnabled: highAccuracyEnabled,
                    osSupportsPrivateCloud: true,
                    pccAvailability: availability,
                    pccSupportsLocale: supportsLocale,
                    quotaState: Self.mapQuota(model.quotaUsage)
                )
            )
        }
        #endif

        return AssistantModelResolver.resolve(
            AssistantModelResolverInput(
                highAccuracyEnabled: highAccuracyEnabled,
                osSupportsPrivateCloud: false,
                pccAvailability: .unsupportedOS,
                pccSupportsLocale: false,
                quotaState: .unavailable
            )
        )
    }

    static func onDeviceAvailability() -> ObservationAdvisorAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                case .appleIntelligenceNotEnabled:
                    return .unavailable(.appleIntelligenceOff)
                @unknown default:
                    return .unavailable(.unknown)
                }
            }
        }
        #endif

        return .unavailable(.unsupportedOS)
    }

    static func settingsStatus() -> AssistantPCCSettingsStatus {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            return AssistantPCCSettingsStatus(
                availability: mapAvailability(model.availability),
                quota: mapQuota(model.quotaUsage)
            )
        }
        #endif

        return AssistantPCCSettingsStatus(availability: .unsupportedOS, quota: .unavailable)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    func makeSession(
        resolution: AssistantModelResolution,
        tools: [any Tool],
        instructions: String
    ) -> LanguageModelSession {
        if resolution.kind == .privateCloud,
           #available(macOS 27.0, iOS 27.0, *) {
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                tools: tools,
                instructions: instructions
            )
        }

        return LanguageModelSession(
            model: .default,
            tools: tools,
            instructions: instructions
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    func contextSize(for resolution: AssistantModelResolution) async -> Int {
        if resolution.kind == .privateCloud,
           #available(macOS 27.0, iOS 27.0, *) {
            return (try? await PrivateCloudComputeLanguageModel().contextSize)
                ?? SystemLanguageModel.default.contextSize
        }

        return SystemLanguageModel.default.contextSize
    }

    @available(macOS 27.0, iOS 27.0, *)
    private static func mapAvailability(
        _ availability: PrivateCloudComputeLanguageModel.Availability
    ) -> AssistantPCCAvailability {
        switch availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.systemNotReady):
            .systemNotReady
        @unknown default:
            .unknown
        }
    }

    @available(macOS 27.0, iOS 27.0, *)
    private static func mapQuota(
        _ quota: PrivateCloudComputeLanguageModel.QuotaUsage
    ) -> AssistantPCCQuotaState {
        switch quota.status {
        case .belowLimit(let status):
            .belowLimit(isApproachingLimit: status.isApproachingLimit, resetDate: quota.resetDate)
        case .limitReached:
            .limitReached(resetDate: quota.resetDate)
        @unknown default:
            .unavailable
        }
    }
    #endif
}

struct AssistantPCCSettingsStatus: Equatable, Sendable {
    let availability: AssistantPCCAvailability
    let quota: AssistantPCCQuotaState

    var isAvailable: Bool {
        availability == .available
    }
}
