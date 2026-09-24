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

/// Option E（KV を正とする）のデータ層と、iCloud への自動追加（rev.5）のテスト。
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

        /// この端末が送った地点として記録された ID。
        var sentIDs: Set<UUID> {
            ids(forKey: FavoriteSyncReconciler.sentIDsKey)
        }

        /// KV で観測した地点として記録された ID。
        var observedIDs: Set<UUID> {
            ids(forKey: FavoriteSyncReconciler.observedIDsKey)
        }

        private func ids(forKey key: String) -> Set<UUID> {
            Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
        }

        func setICloudSyncEnabled(_ isEnabled: Bool) {
            defaults.set(isEnabled, forKey: AppSettingsKeys.iCloudSyncEnabled)
        }

        func makeICloudStore() -> iCloudFavoriteLocationStore {
            iCloudFavoriteLocationStore(kvStore: kvStore, fallbackDefaults: defaults, notificationCenter: center)
        }

        func makeReconciler(activeStore: any FavoriteLocationStoring) -> FavoriteSyncReconciler {
            FavoriteSyncReconciler(
                activeStore: activeStore,
                localDefaults: defaults,
                kvStore: kvStore,
                toggleProvider: { defaults.bool(forKey: AppSettingsKeys.iCloudSyncEnabled) }
            )
        }
    }

    private func makeEnvironment(
        kv: [FavoriteLocation]?,
        local: [FavoriteLocation],
        iCloudSyncEnabled: Bool = true,
        legacyMigrated: Bool = false
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
        if legacyMigrated {
            defaults.set(true, forKey: FavoriteSyncReconciler.legacyMigratedKey)
        }
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
        timeout: TimeInterval = 5.0,
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

    /// 自動追加は次の MainActor の実行に回されるので、「何も起きない」ことを確かめる前に待つ。
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - 自動追加（§15 受け入れ基準 1〜7）

    /// AC1: local=[A,B]、KV=[] で iCloud モードとして起動すると、KV=[A,B] になり、送信済みとして記録され、お知らせは2件になる。
    /// AppController の注入経路で確認する。お知らせは閉じると消え、永続化しない。
    func test_autoUpload_launchUploadsLocalOnlyAndNotifies() throws {
        let env = try makeEnvironment(kv: [], local: [pointA, pointB])

        let appController = AppController(
            calculationService: MockNightCalculationService(),
            favoriteDefaults: env.defaults,
            kvStore: env.kvStore,
            notificationCenter: env.center
        )
        let reconciler = appController.favoriteSyncReconciler

        XCTAssertEqual(reconciler.activeMode, .icloud)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])
        XCTAssertEqual(appController.favoriteStore.loadAll(), [pointA, pointB])
        XCTAssertEqual(env.sentIDs, [pointA.id, pointB.id])
        XCTAssertEqual(reconciler.autoUploadedIDs.count, 2)

        reconciler.dismissAutoUploadNotice()

        XCTAssertTrue(reconciler.autoUploadedIDs.isEmpty)
        XCTAssertTrue(env.makeReconciler(activeStore: env.makeICloudStore()).autoUploadedIDs.isEmpty, "再起動後は出さない")
    }

    /// AC2: 他の端末で削除された地点は、その場でも再起動後も KV に戻さない。
    func test_autoUpload_doesNotResendSpotDeletedOnOtherDevice() async throws {
        let env = try makeEnvironment(kv: [], local: [pointA, pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateServerChange([pointA])
        }
        await settle()
        XCTAssertEqual(env.kvStore.favorites, [pointA])

        let relaunchedStore = env.makeICloudStore()
        let relaunched = env.makeReconciler(activeStore: relaunchedStore)
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertEqual(relaunchedStore.loadAll(), [pointA])
        XCTAssertTrue(relaunched.autoUploadedIDs.isEmpty)
        XCTAssertEqual(env.localFavorites, [pointA, pointB], "ローカルからは消さない")
        withExtendedLifetime(reconciler) {}
    }

    /// AC3: 初回同期前に自動追加した地点が OS に破棄されたら、退避して送り直す（KV=[X, A, B]）。
    func test_autoUpload_resendsSpotsDiscardedByInitialSync() async throws {
        let pointX = FavoriteLocation(name: "X", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: nil, local: [pointA, pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])

        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointX])
        }
        await waitUntil { env.kvStore.favorites == [pointX, self.pointA, self.pointB] }

        XCTAssertEqual(store.loadAll(), [pointX, pointA, pointB])
        XCTAssertEqual(env.localFavorites, [pointA, pointB])
        XCTAssertEqual(env.sentIDs, [pointA.id, pointB.id])
        XCTAssertTrue(env.observedIDs.contains(pointX.id))
        XCTAssertEqual(reconciler.autoUploadedIDs, [pointA.id, pointB.id])
    }

    /// AC4: accountChange では何もしない。前のアカウントで送ったローカルの地点は新しいアカウントに送らない。
    func test_autoUpload_doesNotSendToNewAccount() async throws {
        let env = try makeEnvironment(kv: [], local: [pointA, pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateAccountChange(newValue: [pointC])
        }
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [pointC])
        XCTAssertEqual(store.loadAll(), [pointC])
        XCTAssertEqual(env.localFavorites, [pointA, pointB])
        withExtendedLifetime(reconciler) {}
    }

    /// AC5: 再起動待ちの間は、起動時も iCloud の一覧が変わったときも、手動の追加でも KV に書き込まない。
    func test_autoUpload_pendingRestart_doesNotWriteKV() async throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB])
        let store = env.makeICloudStore()
        env.setICloudSyncEnabled(false)
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertTrue(reconciler.isPendingRestart)

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateServerChange([pointC])
        }
        await settle()

        XCTAssertEqual(reconciler.addToCloud([pointB]), 0)
        XCTAssertEqual(env.kvStore.setCount, 0)
        XCTAssertEqual(store.loadAll(), [pointC])
        XCTAssertTrue(reconciler.autoUploadedIDs.isEmpty)
    }

    /// AC6: KV に既にある地点（ID が違う同一地点を含む）は送らず、送信済みとしてだけ記録する。
    func test_autoUpload_skipsSpotsAlreadyInKVAndRecordsThem() throws {
        let localCopy = FavoriteLocation(name: "ローカル", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let cloudCopy = FavoriteLocation(name: "iCloud", latitude: 36.0005, longitude: 138.0005, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA, cloudCopy], local: [pointA, localCopy])
        let store = env.makeICloudStore()

        let reconciler = env.makeReconciler(activeStore: store)

        XCTAssertEqual(env.kvStore.setCount, 0)
        XCTAssertEqual(store.loadAll(), [pointA, cloudCopy])
        XCTAssertEqual(env.observedIDs, [pointA.id, localCopy.id, cloudCopy.id])
        XCTAssertTrue(env.sentIDs.isEmpty)
        XCTAssertTrue(reconciler.autoUploadedIDs.isEmpty)
    }

    /// AC7: 同じ起動の中で自動追加は冪等。自分の save や外部変更で locations が変わっても二重に書き込まず、
    /// 書き込み後のストアの一覧が確定前の値で上書きされない。
    func test_autoUpload_isIdempotentWithinLaunch() async throws {
        let env = try makeEnvironment(kv: [], local: [pointA, pointB])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.setCount, 1)

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateServerChange([pointA, pointB, pointC])
        }
        await settle()

        XCTAssertEqual(env.kvStore.setCount, 1)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB, pointC])
        XCTAssertEqual(store.loadAll(), [pointA, pointB, pointC])
        XCTAssertEqual(reconciler.autoUploadedIDs, [pointA.id, pointB.id])

        // 初回同期で破棄された後の送り直しも1回だけで、ストアの一覧は KV と一致する。
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointC])
        }
        await waitUntil { env.kvStore.favorites == [self.pointC, self.pointA, self.pointB] }
        await settle()

        XCTAssertEqual(env.kvStore.setCount, 2)
        XCTAssertEqual(store.loadAll(), [pointC, pointA, pointB])
    }

    // MARK: - 送信済みと観測済みの記録、安全網

    /// R1: 記録がなく v1 で iCloud モードを使った端末では、ローカルの全地点を観測済みとして初期化し、送らない。
    /// KV から消えた地点（v1 で削除済み）は設定画面の候補に出るだけ。PR2 のバナーの記録は消す。
    func test_legacyV1User_initializesObservedWithoutSending() async throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointA, pointB], legacyMigrated: true)
        env.defaults.set([pointB.id.uuidString], forKey: "favorites.sync.dismissedLocalOnlyIDs")
        let store = env.makeICloudStore()

        let reconciler = env.makeReconciler(activeStore: store)
        await settle()

        XCTAssertEqual(env.kvStore.setCount, 0)
        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertTrue(env.observedIDs.isSuperset(of: [pointA.id, pointB.id]))
        XCTAssertEqual(reconciler.localOnly, [pointB])
        XCTAssertTrue(reconciler.autoUploadedIDs.isEmpty)
        XCTAssertNil(env.defaults.object(forKey: "favorites.sync.dismissedLocalOnlyIDs"))
    }

    /// R1b: v1 の形跡がなければ、この端末にのみある地点を従来どおり送る。
    func test_withoutLegacyMigration_sendsLocalOnly() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointA, pointB])

        let reconciler = env.makeReconciler(activeStore: env.makeICloudStore())

        XCTAssertEqual(env.kvStore.favorites, [pointA, pointB])
        XCTAssertEqual(reconciler.autoUploadedIDs, [pointB.id])
    }

    /// R1c: v1 向けの初期化は記録がないときの1回だけ。その後にローカルへ入った地点は送る。
    func test_legacyInitialization_runsOnlyWhileNoRecordExists() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointA], legacyMigrated: true)
        _ = env.makeReconciler(activeStore: env.makeICloudStore())
        FavoriteLocationStore(userDefaults: env.defaults).save([pointA, pointC])

        _ = env.makeReconciler(activeStore: env.makeICloudStore())

        XCTAssertEqual(env.kvStore.favorites, [pointA, pointC])
    }

    /// R3: accountChange の直後の initialSyncChange で前のアカウントの地点が退避されても、新しいアカウントには送らない。
    /// 観測しただけの地点（P）も、前のアカウントでこの端末が送った地点（L）も、設定画面の候補に出るだけ。
    func test_initialSyncAfterAccountChange_doesNotSendObservedOnlySpots() async throws {
        let pointL = FavoriteLocation(name: "L", latitude: 38.0, longitude: 140.0, timeZoneIdentifier: "Asia/Tokyo")
        let pointP = FavoriteLocation(name: "P", latitude: 39.0, longitude: 141.5, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointP], local: [pointL])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointP, pointL])

        // 切替の直後は前のアカウントの値が見えたままで、続く初回同期で新しいアカウントの値に置き換わる。
        await applyExternalChange(to: [store]) {
            env.kvStore.simulateAccountChange(newValue: [pointP, pointL])
        }
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [self.pointC])
        }
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [pointC])
        XCTAssertTrue(env.localFavorites.contains(pointP))
        XCTAssertTrue(Set(reconciler.localOnly.map(\.id)).isSuperset(of: [pointL.id, pointP.id]))
    }

    /// R4: OFF のときに取り込んだ地点は観測済みになり、その後ほかの端末で削除されてから ON にしても送り返さない。
    func test_importedSpotDeletedElsewhere_isNotResentAfterTurningOn() throws {
        let pointX = FavoriteLocation(name: "X", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA, pointX], local: [pointA], iCloudSyncEnabled: false)
        let localReconciler = env.makeReconciler(activeStore: FavoriteLocationStore(userDefaults: env.defaults))
        localReconciler.refresh()
        XCTAssertEqual(localReconciler.importToLocal([pointX]), 1)
        XCTAssertEqual(env.observedIDs, [pointX.id])

        env.kvStore.simulateServerChange([pointA])
        env.setICloudSyncEnabled(true)
        let reconciler = env.makeReconciler(activeStore: env.makeICloudStore())

        XCTAssertEqual(env.kvStore.setCount, 0)
        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertEqual(reconciler.localOnly, [pointX])
    }

    /// R5: 自動追加で送った地点を含まない古い配列で save されても、ローカルからは消さない。
    /// 自動では送り直さず設定画面の候補に出し、選べば手動で追加できる。
    func test_staleSaveAfterAutoUpload_keepsSpotInLocalAndListsIt() async throws {
        let pointT = FavoriteLocation(name: "T", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA], local: [pointT])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointT])

        store.save([pointA])
        await settle()

        XCTAssertEqual(env.localFavorites, [pointT])
        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertEqual(reconciler.localOnly, [pointT])

        XCTAssertEqual(reconciler.addToCloud([pointT]), 1)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointT])
        XCTAssertTrue(reconciler.localOnly.isEmpty)
    }

    /// R5b: 自動追加した地点も、ViewModel が追いついた後（メインキューの次のターン以降）に明示的に削除すれば、
    /// ローカルからも取り除き、設定画面の候補に出さない。
    func test_explicitDeleteAfterAutoUpload_prunesLocal() async throws {
        let pointT = FavoriteLocation(name: "T", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA], local: [pointT])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointT])
        await settle()

        store.save([pointA])
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertTrue(env.localFavorites.isEmpty)
        XCTAssertTrue(reconciler.localOnly.isEmpty)
    }

    /// R5c: 自動追加の直後、ViewModel がまだ追いついていない同じターンに古い配列で save しても、追加した地点は刈り込まない。
    /// `receive(on: DispatchQueue.main)` で購読する SidebarViewModel を経由して確かめる。
    func test_sidebarStaleSaveRightAfterAutoUpload_keepsSpotInLocal() async throws {
        let pointT = FavoriteLocation(name: "T", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA], local: [pointT])
        let store = env.makeICloudStore()
        let locationController = MockLocationController()
        locationController.selectedLocation = CLLocationCoordinate2D(latitude: 33.0, longitude: 131.0)
        locationController.locationName = "新しい地点"
        let sidebar = SidebarViewModel(
            locationController: locationController,
            lightPollutionService: MockLightPollutionService(),
            favoriteStore: store
        )
        let reconciler = env.makeReconciler(activeStore: store)
        XCTAssertEqual(env.kvStore.favorites, [pointA, pointT])
        XCTAssertEqual(sidebar.favorites, [pointA], "同じターンではまだ追いついていない")

        sidebar.addCurrentLocationToFavorites()
        await settle()

        XCTAssertEqual(env.localFavorites, [pointT])
        XCTAssertEqual(reconciler.localOnly, [pointT])
    }

    /// R7: 60KB を超えて KV に書かずに fallback へ回ったときは、送ったとみなさない（記録も通知もしない）。
    func test_autoUploadOverSizeLimit_isNotRecordedOrNotified() async throws {
        let many = (0..<600).map { index in
            FavoriteLocation(
                name: "地点\(index)",
                latitude: 10.0 + Double(index) * 0.01,
                longitude: 120.0,
                timeZoneIdentifier: "Asia/Tokyo"
            )
        }
        XCTAssertGreaterThan(try JSONEncoder().encode(many).count, 60 * 1_024)
        let env = try makeEnvironment(kv: [], local: many)

        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [])
        XCTAssertEqual(env.kvStore.setCount, 0)
        XCTAssertTrue(env.sentIDs.isEmpty)
        XCTAssertTrue(env.observedIDs.isEmpty)
        XCTAssertTrue(reconciler.autoUploadedIDs.isEmpty)
        // 送れない一覧で表示中の一覧を膨らませない。膨らむと、その後の利用者の編集まで KV に届かなくなる。
        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(reconciler.localOnly.count, many.count)

        store.save([pointA])
        XCTAssertEqual(env.kvStore.favorites, [pointA])
    }

    /// R6: お知らせの件数と送信済みの記録は、実際に保存された地点で数える（同一地点どうしは1件）。
    func test_autoUploadNotice_countsOnlySavedSpots() throws {
        let nearA = FavoriteLocation(name: "A'", latitude: 35.0005, longitude: 139.0005, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [], local: [pointA, nearA])

        let reconciler = env.makeReconciler(activeStore: env.makeICloudStore())

        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertEqual(reconciler.autoUploadedIDs, [pointA.id])
        XCTAssertEqual(env.sentIDs, [pointA.id])
    }

    // MARK: - 3: 初回同期前の二重生成

    /// 3: 初回同期前にストアを2回生成しても、ローカルの地点は失われず、破棄された分は送り直される。
    func test_twoStoresBeforeInitialSync_doNotLoseLocal() async throws {
        let env = try makeEnvironment(kv: nil, local: [pointB])
        let first = env.makeICloudStore()
        let second = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: second)

        await applyExternalChange(to: [first, second]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }
        await waitUntil { env.kvStore.favorites == [self.pointA, self.pointB] }

        XCTAssertEqual(env.localFavorites, [pointB])
        withExtendedLifetime(reconciler) {}
    }

    // MARK: - 4 / 4b: 初回同期での退避

    /// 4: 初回同期前に iCloud モードで保存した地点は、OS に破棄される前にローカルへ退避される。
    /// reconciler が送った地点ではない（KV で観測しただけ）ので自動では送り直さず、設定画面の候補に出す。
    func test_initialSync_evacuatesEditDiscardedByOS() async throws {
        let env = try makeEnvironment(kv: nil, local: [])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        store.save([pointD])
        await settle()
        await applyExternalChange(to: [store]) {
            env.kvStore.completeInitialSync(server: [pointA])
        }
        await settle()

        XCTAssertEqual(env.localFavorites, [pointD])
        XCTAssertEqual(store.loadAll(), [pointA])
        XCTAssertEqual(reconciler.localOnly, [pointD])
    }

    /// 4b: initialSyncChange は changedKeys が空でも、対象キーを含まなくても退避する。
    func test_initialSync_evacuatesRegardlessOfChangedKeys() async throws {
        for changedKeys in [[], ["other.key"]] {
            let env = try makeEnvironment(kv: nil, local: [])
            let store = env.makeICloudStore()

            store.save([pointD])
            await applyExternalChange(to: [store]) {
                env.kvStore.completeInitialSync(server: [pointA], changedKeys: changedKeys)
            }

            XCTAssertEqual(store.loadAll(), [pointA], "changedKeys=\(changedKeys)")
            XCTAssertEqual(env.localFavorites, [pointD], "changedKeys=\(changedKeys)")
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

    /// 5: iCloud モードで削除した地点はローカルからも消え、再起動しても KV に戻らない。
    func test_deleteInICloud_reflectsToLocalAcrossRestarts() async throws {
        let env = try makeEnvironment(kv: [pointA, pointB], local: [pointA, pointB])
        let store = env.makeICloudStore()

        store.save([pointA])

        XCTAssertEqual(env.localFavorites, [pointA])
        for _ in 0..<3 {
            let relaunched = env.makeICloudStore()
            let reconciler = env.makeReconciler(activeStore: relaunched)
            await settle()
            XCTAssertEqual(relaunched.loadAll(), [pointA])
            XCTAssertEqual(env.kvStore.favorites, [pointA])
            XCTAssertEqual(env.localFavorites, [pointA])
            withExtendedLifetime(reconciler) {}
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

    /// 6: OFF の間にローカルへ追加した地点は、ON にして起動すると自動で KV に入る。
    func test_localAddedWhileOff_isUploadedAfterTurningOn() throws {
        let env = try makeEnvironment(kv: [pointA], local: [], iCloudSyncEnabled: false)
        FavoriteLocationStore(userDefaults: env.defaults).save([pointC])

        env.setICloudSyncEnabled(true)
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        XCTAssertEqual(env.kvStore.favorites, [pointA, pointC])
        XCTAssertEqual(reconciler.autoUploadedIDs, [pointC.id])
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

    /// 8: accountChange では退避しない。前のアカウントの地点はローカルに入らず、ローカルの地点も新しいアカウントに送らない。
    func test_accountChange_doesNotEvacuatePreviousAccount() async throws {
        let pointL = FavoriteLocation(name: "L", latitude: 38.0, longitude: 140.0, timeZoneIdentifier: "Asia/Tokyo")
        let pointP = FavoriteLocation(name: "P", latitude: 39.0, longitude: 141.5, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointP], local: [pointL])
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)

        await applyExternalChange(to: [store]) {
            env.kvStore.simulateAccountChange(newValue: nil)
        }
        await settle()

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(env.localFavorites, [pointL])
        XCTAssertNil(env.kvStore.favorites)
        withExtendedLifetime(reconciler) {}
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

    // MARK: - 10: 再起動待ち

    /// 10: local モードでトグルと稼働中のモードが食い違っている間は、取り込みが0件を返して何もしない。
    func test_pendingRestart_disablesImportToLocal() throws {
        let env = try makeEnvironment(kv: [pointA], local: [pointB], iCloudSyncEnabled: false)
        let store = FavoriteLocationStore(userDefaults: env.defaults)
        let reconciler = env.makeReconciler(activeStore: store)
        env.setICloudSyncEnabled(true)

        XCTAssertTrue(reconciler.isPendingRestart)
        XCTAssertEqual(reconciler.importToLocal([pointA]), 0)
        XCTAssertEqual(store.loadAll(), [pointB])
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
    /// ローカルの同一地点を自動追加しないよう、v1 の利用者（ローカルは観測済み）として起動する。
    func test_dashboardAddThenRemove_reflectsToKVAndLocal() async throws {
        let localCopy = FavoriteLocation(name: "X（端末）", latitude: 36.0, longitude: 138.0, timeZoneIdentifier: "Asia/Tokyo")
        let env = try makeEnvironment(kv: [pointA], local: [localCopy], legacyMigrated: true)
        let store = env.makeICloudStore()
        let reconciler = env.makeReconciler(activeStore: store)
        let dashboard = DashboardViewModel(comparisonController: StubComparisonController(), favoriteStore: store)
        XCTAssertEqual(reconciler.localOnly, [localCopy])

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
        await settle()

        XCTAssertEqual(env.kvStore.favorites, [pointA])
        XCTAssertTrue(env.localFavorites.isEmpty)
        XCTAssertTrue(reconciler.localOnly.isEmpty)
    }

    // MARK: - トグルの変更

    /// トグルを切り替えると objectWillChange が1回だけ届き、再起動待ちになる。
    /// 書き込みが非メインスレッドからでも trap しないこと、トグル以外の書き込みでは通知しないことも確かめる。
    func test_toggleChange_notifiesObjectWillChangeOnce() async throws {
        for writesOffMain in [false, true] {
            let env = try makeEnvironment(kv: [pointA], local: [])
            let reconciler = env.makeReconciler(activeStore: env.makeICloudStore())
            XCTAssertFalse(reconciler.isPendingRestart)

            var changeCount = 0
            let cancellable = reconciler.objectWillChange.sink { changeCount += 1 }
            let defaults = env.defaults
            if writesOffMain {
                await Task.detached {
                    XCTAssertFalse(Thread.isMainThread)
                    defaults.set(false, forKey: AppSettingsKeys.iCloudSyncEnabled)
                }.value
            } else {
                env.setICloudSyncEnabled(false)
            }
            await waitUntil { changeCount > 0 }

            XCTAssertEqual(changeCount, 1, "writesOffMain: \(writesOffMain)")
            XCTAssertTrue(reconciler.isPendingRestart)

            defaults.set(false, forKey: AppSettingsKeys.iCloudSyncEnabled)
            defaults.set("unrelated", forKey: "FavoriteSyncReconcilerTests.unrelated")
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(changeCount, 1, "トグルの値が変わらない書き込みでは通知しない")
            withExtendedLifetime(cancellable) {}
        }
    }
}
