import XCTest
@testable import NightScope

final class AssistantModelResolverTests: XCTestCase {
    func test_disabledHighAccuracyUsesOnDeviceWithoutFallbackReason() {
        let result = AssistantModelResolver.resolve(input(highAccuracyEnabled: false))

        XCTAssertEqual(result, AssistantModelResolution(kind: .onDevice, fallbackReason: nil))
    }

    func test_unsupportedOSFallsBackToOnDevice() {
        let result = AssistantModelResolver.resolve(input(osSupportsPrivateCloud: false))

        XCTAssertEqual(result, AssistantModelResolution(kind: .onDevice, fallbackReason: .unsupportedOS))
    }

    func test_unavailablePCCFallsBackToOnDevice() {
        let result = AssistantModelResolver.resolve(input(pccAvailability: .systemNotReady))

        XCTAssertEqual(result, AssistantModelResolution(kind: .onDevice, fallbackReason: .unavailable))
    }

    func test_unsupportedLocaleFallsBackToOnDevice() {
        let result = AssistantModelResolver.resolve(input(pccSupportsLocale: false))

        XCTAssertEqual(result, AssistantModelResolution(kind: .onDevice, fallbackReason: .unsupportedLocale))
    }

    func test_quotaLimitFallsBackToOnDevice() {
        let result = AssistantModelResolver.resolve(
            input(quotaState: .limitReached(resetDate: Date(timeIntervalSince1970: 0)))
        )

        XCTAssertEqual(result, AssistantModelResolution(kind: .onDevice, fallbackReason: .quotaLimitReached))
    }

    func test_availablePCCUsesPrivateCloud() {
        let result = AssistantModelResolver.resolve(input())

        XCTAssertEqual(result, AssistantModelResolution(kind: .privateCloud, fallbackReason: nil))
    }

    func test_approachingQuotaStillUsesPrivateCloud() {
        let result = AssistantModelResolver.resolve(
            input(quotaState: .belowLimit(isApproachingLimit: true, resetDate: nil))
        )

        XCTAssertEqual(result.kind, .privateCloud)
        XCTAssertNil(result.fallbackReason)
    }

    private func input(
        highAccuracyEnabled: Bool = true,
        osSupportsPrivateCloud: Bool = true,
        pccAvailability: AssistantPCCAvailability = .available,
        pccSupportsLocale: Bool = true,
        quotaState: AssistantPCCQuotaState = .belowLimit(isApproachingLimit: false, resetDate: nil)
    ) -> AssistantModelResolverInput {
        AssistantModelResolverInput(
            highAccuracyEnabled: highAccuracyEnabled,
            osSupportsPrivateCloud: osSupportsPrivateCloud,
            pccAvailability: pccAvailability,
            pccSupportsLocale: pccSupportsLocale,
            quotaState: quotaState
        )
    }
}
