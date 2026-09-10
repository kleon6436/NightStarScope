import XCTest
@testable import NightScope

@MainActor
final class AssistantModelRuntimeTests: XCTestCase {
    func test_privateCloudComputeIsDisabledWithoutBuildFlag() {
        XCTAssertFalse(AssistantModelRuntime.isPrivateCloudComputeEnabled)
    }

    func test_highAccuracyResolvesToOnDeviceWhenPCCGateIsDisabled() async {
        let defaults = UserDefaults(suiteName: "AssistantModelRuntimeTests") ?? UserDefaults.standard
        defaults.set(true, forKey: "assistantHighAccuracyMode")
        defer { defaults.removeObject(forKey: "assistantHighAccuracyMode") }

        let runtime = AssistantModelRuntime(userDefaults: defaults)
        let resolution = await runtime.resolve(language: "ja")

        XCTAssertEqual(resolution.kind, .onDevice)
    }

    func test_settingsStatusReportsNotEntitledWhenPCCGateIsDisabled() {
        let status = AssistantModelRuntime.settingsStatus()

        XCTAssertEqual(status.availability, .notEntitled)
        XCTAssertFalse(status.isAvailable)
    }
}
