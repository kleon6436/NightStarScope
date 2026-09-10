import XCTest
@testable import NightScope
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    #if canImport(FoundationModels)
    func test_adviceGenerationOptionsAreGreedyAndCapped() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }

        let options = AssistantGenerationOptions.adviceGenerationOptions()

        XCTAssertEqual(options.samplingMode, .greedy)
        XCTAssertNil(options.temperature)
        XCTAssertEqual(options.maximumResponseTokens, 400)
        if #available(macOS 27.0, iOS 27.0, *) {
            XCTAssertEqual(options.toolCallingMode, .allowed)
        }
    }

    func test_conversationGenerationOptionsKeepDefaultSamplingAndCapResponse() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }

        let options = AssistantGenerationOptions.conversationGenerationOptions()

        XCTAssertNil(options.samplingMode)
        XCTAssertNil(options.temperature)
        XCTAssertEqual(options.maximumResponseTokens, 500)
    }
    #endif
}
