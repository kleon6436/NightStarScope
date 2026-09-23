import XCTest
import Combine
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
        var cancellables = Set<AnyCancellable>()
        store.locationsPublisher
            .dropFirst()
            .sink { locations in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(locations, [favorite])
                updated.fulfill()
            }
            .store(in: &cancellables)

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

        withExtendedLifetime(cancellables) {
            wait(for: [updated], timeout: 5)
        }
        XCTAssertEqual(store.loadAll(), [favorite])
    }

    func test_starMapSettingsChanges_postedFromBackground_doesNotTrap() {
        let suiteName = "iCloudFavoriteLocationStoreTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let received = expectation(description: "settings delivered on main")
        received.assertForOverFulfill = false
        let posted = expectation(description: "background post returned")
        var cancellables = Set<AnyCancellable>()
        // first() で打ち切ると、テストホストの main 側の変更通知で購読が先に終わり、
        // バックグラウンドの post がパイプラインを通らないまま green になりうる。
        StarMapSettingsDependency.live.changes
            .sink { _ in
                XCTAssertTrue(Thread.isMainThread)
                received.fulfill()
            }
            .store(in: &cancellables)

        DispatchQueue.global().async {
            // UserDefaults は Sendable でないため、送信側のスレッドで専用 suite を生成する。
            let suiteDefaults = UserDefaults(suiteName: suiteName)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: suiteDefaults)
            posted.fulfill()
        }

        withExtendedLifetime(cancellables) {
            wait(for: [posted, received], timeout: 5)
        }
    }
}
