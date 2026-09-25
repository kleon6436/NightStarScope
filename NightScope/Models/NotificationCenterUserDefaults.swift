import Foundation
import Combine

extension NotificationCenter {
    /// UserDefaults の変更通知をメインキューで配信する。通知は書き込んだスレッドで届くため、購読側の MainActor 処理の前でメインへ移す。
    func userDefaultsChangesOnMain(object: UserDefaults? = nil) -> AnyPublisher<Notification, Never> {
        publisher(for: UserDefaults.didChangeNotification, object: object)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
