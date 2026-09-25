import XCTest
@testable import NightScope

/// 取り込み画面の選択状態と、reconciler と組み合わせたときの追加・取り込み結果のテスト。
@MainActor
final class FavoriteSyncImportSelectionTests: XCTestCase {

    private let pointA = FavoriteLocation(name: "A", latitude: 35.0, longitude: 139.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointB = FavoriteLocation(name: "B", latitude: 34.0, longitude: 135.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointC = FavoriteLocation(name: "C", latitude: 43.0, longitude: 141.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointD = FavoriteLocation(name: "D", latitude: 26.0, longitude: 127.0, timeZoneIdentifier: "Asia/Tokyo")

    private struct Environment {
        let defaults: UserDefaults
        let kvStore: FakeUbiquitousKeyValueStore
        let center: NotificationCenter
    }

    private func makeEnvironment(
        kv: [FavoriteLocation]?,
        local: [FavoriteLocation],
        iCloudSyncEnabled: Bool,
        legacyMigrated: Bool = false
    ) throws -> Environment {
        let suiteName = "FavoriteSyncImportSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        if !local.isEmpty {
            FavoriteLocationStore(userDefaults: defaults).save(local)
        }
        defaults.set(iCloudSyncEnabled, forKey: AppSettingsKeys.iCloudSyncEnabled)
        defaults.set(legacyMigrated, forKey: FavoriteSyncReconciler.legacyMigratedKey)
        return Environment(
            defaults: defaults,
            kvStore: FakeUbiquitousKeyValueStore(center: center, favorites: kv),
            center: center
        )
    }

    private func makeReconciler(
        _ env: Environment,
        activeStore: any FavoriteLocationStoring
    ) -> FavoriteSyncReconciler {
        FavoriteSyncReconciler(
            activeStore: activeStore,
            localDefaults: env.defaults,
            kvStore: env.kvStore,
            toggleProvider: { env.defaults.bool(forKey: AppSettingsKeys.iCloudSyncEnabled) }
        )
    }

    // MARK: - 選択状態

    func test_defaultIsUnselected() {
        let selection = FavoriteSyncImportSelection()

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertFalse(selection.isSelected(pointA))
        XCTAssertFalse(selection.isAllSelected(in: [pointA, pointB]))
    }

    func test_toggleAndSelectAll() {
        var selection = FavoriteSyncImportSelection()

        selection.toggle(pointA)
        XCTAssertTrue(selection.isSelected(pointA))
        selection.toggle(pointA)
        XCTAssertFalse(selection.isSelected(pointA))

        selection.selectAll(in: [pointA, pointB])
        XCTAssertTrue(selection.isAllSelected(in: [pointA, pointB]))
        XCTAssertFalse(selection.isAllSelected(in: []))
    }

    func test_deselectAll_clearsSelection() {
        var selection = FavoriteSyncImportSelection()
        selection.selectAll(in: [pointA, pointB])

        selection.deselectAll()

        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertFalse(selection.isAllSelected(in: [pointA, pointB]))
    }

    func test_prune_dropsLocationsNoLongerListed() {
        var selection = FavoriteSyncImportSelection()
        selection.selectAll(in: [pointA, pointB])

        selection.prune(to: [pointB, pointC])

        XCTAssertEqual(selection.selectedIDs, [pointB.id])
    }

    func test_commit_passesSelectedInListOrderAndClearsSelection() {
        var selection = FavoriteSyncImportSelection()
        selection.toggle(pointC)
        selection.toggle(pointA)
        var received: [[FavoriteLocation]] = []

        let first = selection.commit(from: [pointA, pointB, pointC]) { selected in
            received.append(selected)
            return selected.count
        }
        let second = selection.commit(from: [pointA, pointB, pointC]) { selected in
            received.append(selected)
            return selected.count
        }

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(received, [[pointA, pointC]])
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    // MARK: - reconciler との組み合わせ

    /// iCloud モードで一部だけ選んで追加すると、選んだ地点だけが KV に入り、二重実行しても重複しない。
    /// ローカルの地点を自動追加しないよう、v1 の利用者（ローカルは観測済み）として起動する。
    func test_iCloudMode_partialSelection_addsOnlySelectedAndDoubleTapDoesNotDuplicate() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB, pointC], iCloudSyncEnabled: true, legacyMigrated: true)
        let store = iCloudFavoriteLocationStore(
            kvStore: env.kvStore,
            fallbackDefaults: env.defaults,
            notificationCenter: env.center
        )
        let reconciler = makeReconciler(env, activeStore: store)
        XCTAssertEqual(reconciler.localOnly, [pointB, pointC])
        var selection = FavoriteSyncImportSelection()
        selection.toggle(pointB)

        let added = selection.commit(from: reconciler.localOnly) { reconciler.addToCloud($0) }
        let setCountAfterFirst = env.kvStore.setCount
        let addedAgain = selection.commit(from: reconciler.localOnly) { reconciler.addToCloud($0) }

        XCTAssertEqual(added, 1)
        XCTAssertEqual(addedAgain, 0)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])
        XCTAssertEqual(env.kvStore.setCount, setCountAfterFirst)
        XCTAssertEqual(reconciler.localOnly, [pointC])
        // 追加してもローカルの一覧は変わらない（ローカルには書かない）。
        XCTAssertEqual(FavoriteLocationStore.loadFavorites(userDefaults: env.defaults), [pointB, pointC])
    }

    /// 同じ候補を2回まとめて渡しても、reconciler 側の和集合で重複しない。
    func test_iCloudMode_sameSelectionTwice_doesNotDuplicate() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB], iCloudSyncEnabled: true, legacyMigrated: true)
        let store = iCloudFavoriteLocationStore(
            kvStore: env.kvStore,
            fallbackDefaults: env.defaults,
            notificationCenter: env.center
        )
        let reconciler = makeReconciler(env, activeStore: store)

        XCTAssertEqual(reconciler.addToCloud([pointB]), 1)
        XCTAssertEqual(reconciler.addToCloud([pointB]), 0)
        XCTAssertEqual(store.loadAll(), [pointA, pointB])
    }

    /// local モードでは iCloud にのみある地点を選んで取り込み、候補から消える。
    func test_localMode_importSelected_updatesLocalAndCandidates() throws {
        let env = try makeEnvironment(kv: [pointA, pointD], local: [pointB], iCloudSyncEnabled: false)
        let store = FavoriteLocationStore(userDefaults: env.defaults)
        let reconciler = makeReconciler(env, activeStore: store)
        reconciler.refresh()
        XCTAssertEqual(reconciler.cloudOnly, [pointA, pointD])
        var selection = FavoriteSyncImportSelection()
        selection.toggle(pointD)

        let added = selection.commit(from: reconciler.cloudOnly) { reconciler.importToLocal($0) }

        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.loadAll(), [pointB, pointD])
        XCTAssertEqual(reconciler.cloudOnly, [pointA])
    }
}
