import Foundation

enum ObservationAdvisorDebounce {
    static let delay: Duration = .milliseconds(500)

    static func wait() async -> Bool {
        do {
            try await Task.sleep(for: delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
