import Foundation

extension NotificationCenter {
    /// UserDefaults の変更通知を AsyncSequence で返す（すべての UserDefaults が対象）。
    /// 通知は書き込んだスレッドで届くが、MainActor の Task で反復すればループ本体はメインで動く。
    func userDefaultsChanges() -> Notifications {
        notifications(named: UserDefaults.didChangeNotification)
    }
}
