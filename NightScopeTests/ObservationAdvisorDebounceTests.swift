import XCTest
@testable import NightScope

final class ObservationAdvisorDebounceTests: XCTestCase {
    func test_waitUsesHalfSecondDelay() {
        XCTAssertEqual(ObservationAdvisorDebounce.delay, .milliseconds(500))
    }

    func test_cancelledWaitDoesNotResumeWork() async {
        let task = Task {
            await ObservationAdvisorDebounce.wait()
        }
        task.cancel()

        let didProceed = await task.value
        XCTAssertFalse(didProceed)
    }
}
