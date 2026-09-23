import XCTest
import Combine
import CoreLocation
@testable import NightScope

/// 初回同期前の書き込みは破棄される、という OS の挙動を模擬するフェイク KV ストア。
/// 外部変更の通知は、実機と同じく非メインスレッドから注入した center に post する。
final class FakeUbiquitousKeyValueStore: UbiquitousKeyValueStoring, @unchecked Sendable {
    static let key = iCloudFavoriteLocationStore.iCloudKey

    private let center: NotificationCenter
    private var cache: [String: Data] = [:]
    private(set) var setCount = 0
    private(set) var synchronizeCount = 0
    private(set) var readCount = 0

    init(center: NotificationCenter, favorites: [FavoriteLocation]? = nil) {
        self.center = center
        cache[Self.key] = favorites.flatMap { try? JSONEncoder().encode($0) }
    }

    /// 現在キャッシュにあるお気に入り（キーがなければ nil）。
    var favorites: [FavoriteLocation]? {
        cache[Self.key].flatMap { try? JSONDecoder().decode([FavoriteLocation].self, from: $0) }
    }

    func data(forKey aKey: String) -> Data? {
        readCount += 1
        return cache[aKey]
    }

    func set(_ aData: Data?, forKey aKey: String) {
        setCount += 1
        cache[aKey] = aData
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }

    /// 初回同期を完了させる。初回同期前にキャッシュへ入った書き込みを破棄して server の値に置き換える。
    func completeInitialSync(server: [FavoriteLocation]?, changedKeys: [String] = [key]) {
        replace(with: server)
        post(reason: NSUbiquitousKeyValueStoreInitialSyncChange, changedKeys: changedKeys)
    }

    func simulateAccountChange(newValue: [FavoriteLocation]?, changedKeys: [String] = [key]) {
        replace(with: newValue)
        post(reason: NSUbiquitousKeyValueStoreAccountChange, changedKeys: changedKeys)
    }

    func simulateServerChange(_ newValue: [FavoriteLocation]?) {
        replace(with: newValue)
        post(reason: NSUbiquitousKeyValueStoreServerChange, changedKeys: [Self.key])
    }

    private func replace(with favorites: [FavoriteLocation]?) {
        cache = [:]
        cache[Self.key] = favorites.flatMap { try? JSONEncoder().encode($0) }
    }

    /// 非メインスレッドから post し、observer の呼び出しが終わるまで待つ。
    private func post(reason: Int, changedKeys: [String]) {
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [center] in
            center.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: self,
                userInfo: [
                    NSUbiquitousKeyValueStoreChangeReasonKey: reason,
                    NSUbiquitousKeyValueStoreChangedKeysKey: changedKeys
                ]
            )
            posted.signal()
        }
        posted.wait()
    }
}

/// Option E（KV を正とし、差分を選んで取り込む）のデータ層のテスト。
@MainActor
final class FavoriteSyncReconcilerTests: XCTestCase {

    private let pointA = FavoriteLocation(name: "A", latitude: 35.0, longitude: 139.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointB = FavoriteLocation(name: "B", latitude: 34.0, longitude: 135.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointC = FavoriteLocation(name: "C", latitude: 43.0, longitude: 141.0, timeZoneIdentifier: "Asia/Tokyo")
    private let pointD = FavoriteLocation(name: "D", latitude: 26.0, longitude: 127.0, timeZoneIdentifier: "Asia/Tokyo")

    /// テストごとに専用 suite の UserDefaults、NotificationCenter、フェイク KV を用意する。
    @MainActor
    private struct Environment {
        let defaults: UserDefaults
        let center: NotificationCenter
        let kvStore: FakeUbiquitousKeyValueStore

        var localFavorites: [FavoriteLocation] {
            FavoriteLocationStore.loadFavorites(userDefaults: defaults)
        }

        func setICloudSyncEnabled(_ isEnabled: Bool) {
            defaults.set(isEnabled, forKey: "iCloudSyncEnabled")
        }

        func makeICloudStore() -> iCloudFavoriteLocationStore {
            iCloudFavoriteLocationStore(kvStore: kvStore, fallbackDefaults: defaults, notificationCenter: center)
        }

        func makeReconciler(activeStore: any FavoriteLocationStoring) -> FavoriteSyncReconciler {
            FavoriteSyncReconciler(
                activeStore: activeStore,
                localDefaults: defaults,
                kvStore: kvStore,
                toggleProvider: { defaults.bool(forKey: "iCloudSyncEnabled") }
            )
        }
    }

    private func makeEnvironment(
        kv: [FavoriteLocation]?,
        local: [FavoriteLocation],
        iCloudSyncEnabled: Bool = true
    ) throws -> Environment {
        let suiteName = "FavoriteSyncReconcilerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let environment = Environment(
            defaults: defaults,
            center: center,
            kvStore: FakeUbiquitousKeyValueStore(center: center, favorites: kv)
        )
        if !local.isEmpty {
            FavoriteLocationStore(userDefaults: defaults).save(local)
        }
        environment.setICloudSyncEnabled(iCloudSyncEnabled)
        return environment
    }

    /// 外部変更の通知を送り、各ストアがメインで反映し終えるまで待つ。
    private func applyExternalChange(to stores: [iCloudFavoriteLocationStore], post: () -> Void) async {
        var cancellables = Set<AnyCancellable>()
        let expectations = stores.map { store in
            let applied = expectation(description: "external change applied")
            applied.assertForOverFulfill = false
            store.locationsPublisher
                .dropFirst()
                .sink { _ in applied.fulfill() }
                .store(in: &cancellables)
            return applied
        }
        post()
        await fulfillment(of: expectations, timeout: 5)
        withExtendedLifetime(cancellables) {}
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件を満たすまでにタイムアウトしました", file: file, line: line)
    }

    // MARK: - 1〜3: 起動と初回同期

    /// 1: 起動時は KV を正とし、自動移行しない（KV への書き込み0回）。AppController の注入経路で確認する。
    func test_launch_showsKVAndListsLocalOnly_withoutWritingKV() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB])

        let appController = AppController(
            calculationService: MockNightCalculationService(),
            favoriteDefaults: env.defaults,
            kvStore: env.kvStore,
            notificationCenter: env.center
        )

        XCTAssertEqual(appController.favoriteStore.loadAll(), [pointA])
        XCTAssertEqual(appController.favoriteSyncReconciler.activeMode, .icloud)
        XCTAssertEqual(appController.favoriteSyncReconciler.localOnly, [pointB])
        XCTAssertEqual(env.kvStore.setCount, 0)
    }

    /// 2: 初回同期前に取り込んだ地点が OS に破棄されても、ローカルに残っているので候補から消えない。
    func test_addToCloudBeforeInitialSync_keepsLocalOnlyAfterSync() async throws {
        let env = try makeEnvironment(kv: nil, local: [pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        XCTAssertEqual(reconciler.addToCloud([pointB]), 1)
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }

        XCTAssertEqual(store.loadAll(), [pointA])
        XCTAssertTrue(reconciler.localOnly.contains(pointB))
    }

    /// 3: 初回同期前にストアを2回生成しても、ローカルの地点は失われない。
    func test_twoStoresBeforeInitialSync_doNotLoseLocal() async throws {
        let env = try makeEnvironment(kv: nil, local: [pointB])
        let first = env.makeICloudStore()
        let second = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: second)

        await applyExternalChange(to: [first, second]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }

        XCTAssertEqual(env.localFavorites, [pointB])
        XCTAssertEqual(reconciler.localOnly, [pointB])
    }

    // MARK: - 4 / 4b: 初回同期での退避

    /// 4: 初回同期前に iCloud モードで保存した地点は、OS に破棄される前にローカルへ退避される。
    func test_initialSync_evacuatesEditDiscardedByOS() async throws {
        let env = try makeEnvironment(kv: nil, local: [])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        store.save([pointD])
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }

        XCTAssertEqual(store.loadAll(), [pointA])
        XCTAssertEqual(env.localFavorites, [pointD])
        XCTAssertTrue(reconciler.localOnly.contains(pointD))
    }

    /// 4b: initialSyncChange は changedKeys が空でも、対象キーを含まなくても退避する。
    func test_initialSync_evacuatesRegardlessOfChangedKeys() async throws {
        for changedKeys in [[], ["other.key"]] {
            let env = try makeEnvironment(kv: nil, local: [])
            let store = env.makeICloudStore()
            let reconciler = env.makeReconciler(activeStore: store)

            store.save([pointD])
            await applyExternalChange(to: [store]) {
                env.kvStore.completeInitialSync(server: [pointA], changedKeys: changedKeys)
            }

            XCTAssertEqual(store.loadAll(), [pointA], "changedKeys=\(changedKeys)")
            XCTAssertEqual(env.localFavorites, [pointD], "changedKeys=\(changedKeys)")
            XCTAssertTrue(reconciler.localOnly.contains(pointD), "changedKeys=\(changedKeys)")
        }
    }

    /// 4c: 退避の後の save は、初回同期で破棄された地点を「この端末で削除した」とみなさず、ローカルに残す。
    func test_saveAfterEvacuation_keepsEvacuatedSpotInLocal() async throws {
        let pointE = FavoriteLocation(name: "E", latitude: 33.0, longitude: 130.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: nil, local: [])
        let store = env.makeICloudStore()

        store.save([pointD])
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }
        XCTAssertEqual(env.localFavorites, [pointD])

        store.save([pointA, pointE])

        XCTAssertEqual(env.localFavorites, [pointD])
    }

    // MARK: - 5 / 11: 削除の反映

    /// 5: iCloud モードで削除した地点はローカルからも消え、再起動しても候補に戻らない。
    func test_deleteInICloud_reflectsToLocalAcrossRestarts() throws {
        let env = try makeEnvironment(kv: [pointA, pointB], local: [pointA, pointB])
        let store = env.makeICloudStore()

        store.save([pointA])

        XCTAssertEqual(env.localFavorites, [pointA])
        for _ in 0..<3 {
            let relaunched = env.makeICloudStore()
            let reconciler = env.makeReconciler(activeStore: relaunched)
            XCTAssertEqual(relaunched.loadAll(), [pointA])
            XCTAssertFalse(reconciler.localOnly.contains(pointB))
            XCTAssertEqual(env.localFavorites, [pointA])
        }
    }

    /// 11: 古い配列のまま save しても、直前の save の後に他の端末から届いた地点はローカルから消さない。
    func test_staleArraySave_doesNotPruneSpotDeliveredByServer() async throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointA, pointB])
        let store = env.makeICloudStore()

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateServerChange([pointA, pointB])
        }
        XCTAssertEqual(store.loadAll(), [pointA, pointB])

        store.save([pointA])

        XCTAssertEqual(env.localFavorites, [pointA, pointB])
    }

    /// 11b: 他の端末で削除された地点は、次の save で「この端末で削除した」とみなさず、ローカルに残す。
    func test_saveAfterServerDeletion_keepsSpotInLocal() async throws {
        let env = try makeEnvironment(kv: [pointA, pointB], local: [pointA, pointB])
        let store = env.makeICloudStore()

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateServerChange([pointA])
        }
        XCTAssertEqual(store.loadAll(), [pointA])

        store.save([pointA, pointC])

        XCTAssertEqual(env.localFavorites, [pointA, pointB])
    }

    // MARK: - 6〜7: OFF と ON の往復

    /// 6: OFF の間にローカルへ追加した地点は、ON にすると候補に出て、選べば KV に入る。
    func test_localAddedWhileOff_appearsAfterTurningOn() throws {
        let env = try makeEnvironment(kv: [pointA], local: [], iCloudSyncEnabled: false)
        FavoriteLocationStore(userDefaults: env.defaults).save([pointC])

        env.setICloudSyncEnabled(true)
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        XCTAssertTrue(reconciler.localOnly.contains(pointC))
        XCTAssertEqual(reconciler.addToCloud([pointC]), 1)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointC])
        XCTAssertTrue(reconciler.localOnly.isEmpty)
    }

    /// 7: OFF のときに取り込んだ地点は、サイドバーの配列全体の保存で消えない。
    func test_importToLocal_survivesSidebarWholeArraySave() async throws {
        let pointX = FavoriteLocation(name: "X", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointX], local: [pointA], iCloudSyncEnabled: false)
        let store = FavoriteLocationStore(userDefaults: env.defaults)
        let reconciler = env.makeReconciler(activeStore: store)
        let locationController = MockLocationController()
        locationController.selectedLocation = CLLocationCoordinate2D(latitude: 33.0, longitude: 131.0)
        locationController.locationName = "新しい地点"
        let sidebar = SidebarViewModel(
            locationController: locationController,
            lightPollutionService: MockLightPollutionService(),
            favoriteStore: store
        )

        reconciler.refresh()
        XCTAssertEqual(reconciler.cloudOnly, [pointX])
        XCTAssertEqual(reconciler.importToLocal([pointX]), 1)
        XCTAssertTrue(reconciler.cloudOnly.isEmpty)
        await waitUntil { sidebar.favorites.contains(pointX) }

        sidebar.addCurrentLocationToFavorites()

        XCTAssertEqual(store.loadAll().count, 3)
        XCTAssertTrue(env.localFavorites.contains(pointX))
    }

    // MARK: - 8: アカウント切替

    /// 8: accountChange では退避しない。前のアカウントの地点はローカルにも候補にも出ない。
    func test_accountChange_doesNotEvacuatePreviousAccount() async throws {
        let pointL = FavoriteLocation(name: "L", latitude: 38.0, longitude: 140.0, timeZoneIdentifier: "Asia/Tokyo")
        let pointP = FavoriteLocation(name: "P", latitude: 39.0, longitude: 141.5, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointP], local: [pointL])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateAccountChange(newValue: nil)
        }

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(env.localFavorites, [pointL])
        XCTAssertEqual(reconciler.localOnly, [pointL])
    }

    /// 8b: accountChange は changedKeys が空でも KV を読み直し、新しいアカウントの一覧（キーがなければ []）に置き換える。
    func test_accountChange_replacesLocationsRegardlessOfChangedKeys() async throws {
        let pointL = FavoriteLocation(name: "L", latitude: 38.0, longitude: 140.0, timeZoneIdentifier: "Asia/Tokyo")
        let pointP = FavoriteLocation(name: "P", latitude: 39.0, longitude: 141.5, timeZoneIdentifier: "Asia/Tokyo")
        for newValue in [[pointC], nil] as [[FavoriteLocation]?] {
            let env = try makeEnvironment(kv: [pointP], local: [pointL])
            let store = env.makeICloudStore()

            await applyExternalChange(to: [store]) {
                env.kvStore.simulateAccountChange(newValue: newValue, changedKeys: [])
            }

            XCTAssertEqual(store.loadAll(), newValue ?? [], "newValue=\(String(describing: newValue))")
            XCTAssertEqual(env.localFavorites, [pointL], "newValue=\(String(describing: newValue))")
        }
    }

    // MARK: - 9: 同一判定

    /// 9: ID が違っても座標が近ければ同一地点とみなし、候補に出さず、取り込んでも重複しない。
    func test_sameSpotWithDifferentID_isNotLocalOnlyAndNotDuplicated() throws {
        let local = FavoriteLocation(name: "ローカル", latitude: 35.0, longitude: 139.0, timeZoneIdentifier: "Asia/Tokyo")
        let cloud = FavoriteLocation(name: "iCloud", latitude: 35.0005, longitude: 139.0005, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [cloud], local: [local])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        XCTAssertTrue(reconciler.localOnly.isEmpty)
        XCTAssertEqual(reconciler.addToCloud([local]), 0)
        XCTAssertEqual(store.loadAll(), [cloud])
        XCTAssertEqual(env.kvStore.setCount, 0)
    }

    // MARK: - 10: 再起動待ち

    /// 10: トグルと稼働中のモードが食い違っている間は、すべての操作が0件を返して何もしない。
    func test_pendingRestart_disablesAllOperations() throws {
        let iCloudEnv = try makeEnvironment(kv: [pointA], local: [pointB])
        let iCloudStore = iCloudEnv.makeICloudStore()
        let iCloudReconciler = iCloudEnv.makeReconciler(activeStore: iCloudStore)
        iCloudEnv.setICloudSyncEnabled(false)

        XCTAssertTrue(iCloudReconciler.isPendingRestart)
        XCTAssertFalse(iCloudReconciler.isLocalOnlyBannerVisible)
        XCTAssertEqual(iCloudReconciler.addToCloud([pointB]), 0)
        XCTAssertEqual(iCloudReconciler.importToLocal([pointB]), 0)
        XCTAssertEqual(iCloudStore.loadAll(), [pointA])
        XCTAssertEqual(iCloudEnv.kvStore.setCount, 0)

        let localEnv = try makeEnvironment(kv: [pointA], local: [pointB], iCloudSyncEnabled: false)
        let localStore = FavoriteLocationStore(userDefaults: localEnv.defaults)
        let localReconciler = localEnv.makeReconciler(activeStore: localStore)
        localEnv.setICloudSyncEnabled(true)

        XCTAssertTrue(localReconciler.isPendingRestart)
        XCTAssertEqual(localReconciler.importToLocal([pointA]), 0)
        XCTAssertEqual(localReconciler.addToCloud([pointA]), 0)
        XCTAssertEqual(localStore.loadAll(), [pointB])
    }

    // MARK: - 12: observer の解除

    /// 12: deinit の後に通知が来ても、クラッシュも副作用もないことを確かめる契約テスト。
    /// observer の解除と Task 内の weak self のどちらで守られていても通る（KV の読み出しとローカルへの書き込みが起きないことだけを見る）。
    func test_notificationAfterDeinit_hasNoCrashOrSideEffects() async throws {
        let env = try makeEnvironment(kv: [pointA], local: [])
        weak var weakStore: iCloudFavoriteLocationStore?
        do {
            let store = env.makeICloudStore()
            weakStore = store
        }
        XCTAssertNil(weakStore)
        let readCountBeforePost = env.kvStore.readCount

        env.kvStore.completeInitialSync(server: [pointB])
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(env.kvStore.readCount, readCountBeforePost)
        XCTAssertTrue(env.localFavorites.isEmpty)
    }

    // MARK: - 13: OFF のときの cloudOnly

    /// 13: local モードで cloudOnly を計算する前に synchronize() を1回呼ぶ。
    func test_cloudOnly_synchronizesBeforeComputing() throws {
        let env = try makeEnvironment(kv: [pointA, pointB], local: [pointB], iCloudSyncEnabled: false)
        let reconciler = env.makeReconciler(activeStore: FavoriteLocationStore(userDefaults: env.defaults))
        XCTAssertEqual(reconciler.activeMode, .local)
        XCTAssertEqual(env.kvStore.synchronizeCount, 0)

        reconciler.refresh()

        XCTAssertEqual(env.kvStore.synchronizeCount, 1)
        XCTAssertEqual(reconciler.cloudOnly, [pointA])
    }

    // MARK: - 14: ダッシュボード経由の統合テスト

    /// 14: iCloud モードでダッシュボードから追加して削除すると、KV とローカルの両方から消え、候補にも出ない。
    func test_dashboardAddThenRemove_reflectsToKVAndLocal() async throws {
        let localCopy = FavoriteLocation(name: "X（端末）", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA], local: [localCopy])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        let dashboard = DashboardViewModel(comparisonController: StubComparisonController(), favoriteStore: store)

        let outcome = dashboard.registerAndSelect(
            coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: 138.0),
            name: "X",
            timeZoneIdentifier: "Asia/Tokyo"
        )
        guard case .registered(let newID, _) = outcome else {
            return XCTFail("新規登録されること: \(outcome)")
        }
        XCTAssertTrue(reconciler.localOnly.isEmpty)
        await waitUntil { dashboard.availableFavorites.contains { $0.id == newID } }

        dashboard.removeFavorite(newID)

        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertTrue(env.localFavorites.isEmpty)
        XCTAssertTrue(reconciler.localOnly.isEmpty)
    }

    // MARK: - バナーの非表示

    /// 「あとで」で閉じると、localOnly の ID 集合が変わるまでバナーを出さない。
    func test_dismissLocalOnlyBanner_hidesUntilLocalOnlySetChanges() async throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertTrue(reconciler.isLocalOnlyBannerVisible)

        reconciler.dismissLocalOnlyBanner()
        XCTAssertFalse(reconciler.isLocalOnlyBannerVisible)
        XCTAssertFalse(env.makeReconciler(activeStore: store).isLocalOnlyBannerVisible, "非表示は再起動後も保たれる")

        store.save([pointA, pointD])
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }

        XCTAssertEqual(Set(reconciler.localOnly.map(\.id)), [pointB.id, pointD.id])
        XCTAssertTrue(reconciler.isLocalOnlyBannerVisible)
    }

    /// トグルを切り替えると objectWillChange が1回だけ届き、バナーが消えて再起動待ちになる。
    /// 書き込みが非メインスレッドからでも trap しないこと、トグル以外の書き込みでは通知しないことも確かめる。
    func test_toggleChange_notifiesObjectWillChangeOnce() async throws {
        for writesOffMain in [false, true] {
            let env = try makeEnvironment(kv: [pointA], local: [pointB])
            let reconciler = env.makeReconciler(activeStore: env.makeICloudStore())
            XCTAssertTrue(reconciler.isLocalOnlyBannerVisible)
            XCTAssertFalse(reconciler.isPendingRestart)

            var changeCount = 0
            let cancellable = reconciler.objectWillChange.sink { changeCount += 1 }
            let defaults = env.defaults
            if writesOffMain {
                await Task.detached {
                    XCTAssertFalse(Thread.isMainThread)
                    defaults.set(false, forKey: "iCloudSyncEnabled")
                }.value
            } else {
                env.setICloudSyncEnabled(false)
            }
            await waitUntil { changeCount > 0 }

            XCTAssertEqual(changeCount, 1, "writesOffMain: \(writesOffMain)")
            XCTAssertFalse(reconciler.isLocalOnlyBannerVisible)
            XCTAssertTrue(reconciler.isPendingRestart)

            defaults.set(false, forKey: "iCloudSyncEnabled")
            defaults.set("unrelated", forKey: "FavoriteSyncReconcilerTests.unrelated")
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(changeCount, 1, "トグルの値が変わらない書き込みでは通知しない")
            withExtendedLifetime(cancellable) {}
        }
    }
}

@MainActor
private final class StubComparisonController: ComparisonControlling {
    var matrix: ComparisonMatrix = .empty
    var dayCount: Int = DashboardViewModel.dayCount

    func refresh(referenceDate: Date, locations: [FavoriteLocation]?) async {}

    func computeMatrix(referenceDate: Date, locations: [FavoriteLocation]?) async -> ComparisonMatrix {
        matrix
    }
}
