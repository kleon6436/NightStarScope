import XCTest
import Observation
@testable import NightScope

/// 非メインスレッドから届く通知で実行時の隔離チェックが trap しないことを確かめる回帰テスト。
@MainActor
final class iCloudFavoriteLocationStoreTests: XCTestCase {

    nonisolated private static let iCloudKey = "favorites.locations.v1"

    /// 実 iCloud に触れないためのフェイク KV ストア。
    private final class FakeKeyValueStore: UbiquitousKeyValueStoring, @unchecked Sendable {
        var storage: [String: Data] = [:]

        func data(forKey aKey: String) -> Data? { storage[aKey] }
        func set(_ aData: Data?, forKey aKey: String) { storage[aKey] = aData }
        func synchronize() -> Bool { true }
    }

    func test_externalChange_postedFromBackground_doesNotTrapAndUpdatesOnMain() throws {
        let kvStore = FakeKeyValueStore()
        let center = NotificationCenter()
        let suiteName = "iCloudFavoriteLocationStoreTests.\(UUID().uuidString)"
        let fallbackDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { fallbackDefaults.removePersistentDomain(forName: suiteName) }

        let store = iCloudFavoriteLocationStore(
            kvStore: kvStore,
            fallbackDefaults: fallbackDefaults,
            notificationCenter: center
        )
        XCTAssertTrue(store.loadAll().isEmpty)

        let favorite = FavoriteLocation(name: "テスト地点", latitude: 35.0, longitude: 139.0, timeZoneIdentifier: "Asia/Tokyo")
        kvStore.storage[Self.iCloudKey] = try JSONEncoder().encode([favorite])

        let updated = expectation(description: "locations updated on main")
        withObservationTracking {
            _ = store.loadAll()
        } onChange: {
            XCTAssertTrue(Thread.isMainThread)
            updated.fulfill()
        }

        DispatchQueue.global().async {
            center.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kvStore,
                userInfo: [
                    NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
                    NSUbiquitousKeyValueStoreChangedKeysKey: [Self.iCloudKey]
                ]
            )
        }

        wait(for: [updated], timeout: 5)
        XCTAssertEqual(store.loadAll(), [favorite])
    }

    /// バックグラウンドで post された UserDefaults の変更通知が、MainActor で反復する列（`userDefaultsChanges()`）に届く。
    /// `StarMapSettingsDependency.live` など設定の変化を流す列はこの列を元にする。
    /// テストホストの他の変更通知と区別するため、目印を付けて post し、目印の付いた通知だけを数える。
    func test_userDefaultsChanges_postedFromBackground_reachesSequence() {
        let marker = UUID().uuidString
        let received = expectation(description: "background post delivered")
        let posted = expectation(description: "background post returned")
        let started = expectation(description: "iteration started")
        let changes = NotificationCenter.default.userDefaultsChanges()
        let iteration = Task { @MainActor in
            started.fulfill()
            for await notification in changes where notification.userInfo?["marker"] as? String == marker {
                received.fulfill()
                return
            }
        }
        wait(for: [started], timeout: 5)

        DispatchQueue.global().async {
            NotificationCenter.default.post(
                name: UserDefaults.didChangeNotification,
                object: nil,
                userInfo: ["marker": marker]
            )
            posted.fulfill()
        }

        wait(for: [posted, received], timeout: 5)
        iteration.cancel()
    }
}
