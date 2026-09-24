import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.nightscope", category: "FavoriteSyncReconciler")

/// iCloud とこの端末のお気に入りの差分を扱う。
/// iCloud モードでは、この端末にのみある地点のうち未送信かつ未観測のものを自動で iCloud に追加し、
/// 残りの差分は設定画面から選んで追加できるようにする。local モードでは、iCloud にのみある地点のうち選んだものを取り込む。
/// 書き込みはすべて稼働中のストアの `save` を通し、UserDefaults のローカルのお気に入りには直接書かない。
@MainActor
final class FavoriteSyncReconciler: ObservableObject {
    /// 稼働中のストアの同期モード。
    enum Mode: Equatable {
        case icloud
        case local
    }

    /// この端末から iCloud へ送った地点の ID 集合を保存するキー（端末ローカル）。アカウントをまたいで保持する。
    static let sentIDsKey = "favorites.sync.sentIDs"
    /// `sentIDs` のうち、現在のアカウントで送った ID を保存するキー（端末ローカル）。accountChange で空に戻す。
    static let sentIDsCurrentAccountKey = "favorites.sync.sentIDsCurrentAccount"
    /// KV で観測した地点（とそれと同一のローカルの地点、iCloud から取り込んだ地点）の ID 集合を保存するキー（端末ローカル）。
    static let observedIDsKey = "favorites.sync.observedIDs"
    /// v1 の自動移行を実行済みかどうか（v1 で iCloud モードを使った形跡）。読むだけで書かない。
    static let legacyMigratedKey = "favorites.icloud.migrated.v1"
    /// PR2 のバナーの「あとで」の記録。使わなくなったので起動時に消す。
    private static let legacyDismissedLocalOnlyIDsKey = "favorites.sync.dismissedLocalOnlyIDs"

    /// 稼働中のストアの型から決めたモード（トグルの値ではない）。
    let activeMode: Mode
    /// iCloud モードで、この端末にのみある地点（`favorites.locations − activeStore`）。送信済みかどうかに関係なく全件。
    @Published private(set) var localOnly: [FavoriteLocation] = []
    /// local モードで、iCloud にのみある地点（`KV − activeStore`）。`refresh()` で計算する。
    @Published private(set) var cloudOnly: [FavoriteLocation] = []
    /// この起動中に自動で iCloud に追加した地点の ID。お知らせを閉じると空に戻す（永続化しない）。
    @Published private(set) var autoUploadedIDs: Set<UUID> = []

    /// この端末が送った ID（前のアカウントで送ったものを含む）。前のアカウントの地点を新しいアカウントに送らないためのガード。
    private var sentIDs: Set<UUID>
    /// 現在のアカウントで送った ID。初回同期で破棄されたときに送り直す対象を、このアカウントで送った地点に限るために使う。
    private var sentIDsCurrentAccount: Set<UUID>
    /// KV で観測した ID。他の端末で削除された地点や、前のアカウントの地点を送らないためのガード。
    private var observedIDs: Set<UUID>
    private let activeStore: any FavoriteLocationStoring
    private let iCloudStore: iCloudFavoriteLocationStore?
    private let localDefaults: UserDefaults
    private let kvStore: any UbiquitousKeyValueStoring
    private let toggleProvider: () -> Bool
    private var cancellables = Set<AnyCancellable>()

    init(
        activeStore: any FavoriteLocationStoring,
        localDefaults: UserDefaults,
        kvStore: any UbiquitousKeyValueStoring,
        toggleProvider: @escaping () -> Bool
    ) {
        self.activeStore = activeStore
        self.localDefaults = localDefaults
        self.kvStore = kvStore
        self.toggleProvider = toggleProvider
        let iCloudStore = activeStore as? iCloudFavoriteLocationStore
        self.iCloudStore = iCloudStore
        self.activeMode = iCloudStore != nil ? .icloud : .local
        self.sentIDs = Self.loadIDs(localDefaults, forKey: Self.sentIDsKey)
        self.sentIDsCurrentAccount = Self.loadIDs(localDefaults, forKey: Self.sentIDsCurrentAccountKey)
        self.observedIDs = Self.loadIDs(localDefaults, forKey: Self.observedIDsKey)
        localDefaults.removeObject(forKey: Self.legacyDismissedLocalOnlyIDsKey)
        initializeObservedForLegacyUserIfNeeded()
        // isPendingRestart はトグルを読む計算プロパティなので、トグルが変わったら画面に知らせる。
        // UserDefaults の変更通知は書き込んだスレッドで届くため、MainActor に隔離された map の前でメインへ移す。
        NotificationCenter.default.userDefaultsChangesOnMain(object: localDefaults)
            .map { _ in toggleProvider() }
            .prepend(toggleProvider())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        guard let iCloudStore else { return }
        // accountChange の後の初回同期で前のアカウントの地点が退避されても、送り直さないようにする。
        iCloudStore.accountChangedPublisher
            .sink { [weak self] in
                self?.resetSentForCurrentAccount()
            }
            .store(in: &cancellables)
        // 退避の通知は locations の更新より前に届くので、続く locations の変化で退避した地点を送り直せる。
        iCloudStore.evacuatedPublisher
            .sink { [weak self] evacuated in
                self?.forgetSent(evacuated)
            }
            .store(in: &cancellables)
        // 退避と削除の反映は locations を更新する前にローカルへ書き終えているので、この購読だけで差分を拾える。
        // @Published は値の確定前に流れるため、差分は流れてきた値で計算し、save を伴う自動追加は次の実行に回す
        // （ここで save すると確定前の値で上書きされる）。
        iCloudStore.locationsPublisher
            .dropFirst()
            .sink { [weak self] active in
                self?.recomputeLocalOnly(active: active)
                Task { @MainActor in
                    self?.autoUploadIfNeeded()
                }
            }
            .store(in: &cancellables)
        autoUploadIfNeeded()
        recomputeLocalOnly(active: iCloudStore.loadAll())
    }

    /// トグルと稼働中のモードが食い違っている（再起動後に反映される）。この間は取り込みも追加もしない。
    var isPendingRestart: Bool {
        toggleProvider() != (activeMode == .icloud)
    }

    /// 差分を計算し直す。画面の表示時に呼ぶ。
    func refresh() {
        switch activeMode {
        case .icloud:
            recomputeLocalOnly(active: activeStore.loadAll())
        case .local:
            kvStore.synchronize()
            let cloud = iCloudFavoriteLocationStore.loadFromKVStore(kvStore) ?? []
            cloudOnly = cloud.subtracting(activeStore.loadAll())
        }
    }

    /// 選んだ地点を iCloud に追加し、追加した件数を返す。iCloud モードのときだけ使える。
    @discardableResult
    func addToCloud(_ selected: [FavoriteLocation]) -> Int {
        guard activeMode == .icloud, !isPendingRestart else { return 0 }
        let added = addToICloud(selected)
        recordSent(added)
        return added.count
    }

    /// 選んだ地点をこの端末に取り込み、追加した件数を返す。local モードのときだけ使える。
    /// 取り込んだ地点は観測済みとして記録する（あとで他の端末で削除されても、ON にしたときに送り返さない）。
    @discardableResult
    func importToLocal(_ selected: [FavoriteLocation]) -> Int {
        guard activeMode == .local, !isPendingRestart else { return 0 }
        let current = activeStore.loadAll()
        let merged = current.unionPreservingOrder(selected)
        guard merged.count > current.count else { return 0 }
        activeStore.save(merged)
        guard activeStore.loadAll() == merged else { return 0 }
        let added = merged[current.count...]
        observedIDs.formUnion(added.map(\.id))
        saveIDs(observedIDs, forKey: Self.observedIDsKey)
        cloudOnly = cloudOnly.subtracting(merged)
        return added.count
    }

    /// 自動追加のお知らせを閉じる。
    func dismissAutoUploadNotice() {
        autoUploadedIDs = []
    }

    // MARK: - Private

    /// v1 で iCloud モードを使った端末では、ローカルの一覧に iCloud で削除済みの地点が残っている。
    /// 送れば復活するので、記録がまだないときに限り、ローカルの全地点を観測済みとして初期化する（送らない）。
    private func initializeObservedForLegacyUserIfNeeded() {
        let hasRecord = localDefaults.object(forKey: Self.sentIDsKey) != nil
            || localDefaults.object(forKey: Self.observedIDsKey) != nil
        guard !hasRecord, localDefaults.bool(forKey: Self.legacyMigratedKey) else { return }
        let local = FavoriteLocationStore.loadFavorites(userDefaults: localDefaults)
        observedIDs.formUnion(local.map(\.id))
        saveIDs(observedIDs, forKey: Self.observedIDsKey)
        logger.notice("event=legacyObservedInit count=\(local.count, privacy: .public)")
    }

    /// この端末にのみある地点のうち、送信済みでも観測済みでもないものを iCloud に追加する。何度呼んでも同じ地点を二度送らない。
    private func autoUploadIfNeeded() {
        guard activeMode == .icloud, !isPendingRestart else { return }
        let cloud = activeStore.loadAll()
        let local = FavoriteLocationStore.loadFavorites(userDefaults: localDefaults)
        // KV にある地点と、それと同一のローカルの地点は観測済みとして記録する。
        // 一覧ではなく KV を読むのは、60KB を超えて fallback にだけ保存された地点を観測済みにしないため。
        let kv = iCloudFavoriteLocationStore.loadFromKVStore(kvStore) ?? []
        let sameSpots = local.filter { spot in kv.contains { spot.isSameSpot(as: $0) } }
        let observed = observedIDs.union(kv.map(\.id)).union(sameSpots.map(\.id))
        if observed != observedIDs {
            observedIDs = observed
            saveIDs(observedIDs, forKey: Self.observedIDsKey)
        }
        let excluded = sentIDs.union(observedIDs)
        let targets = local.subtracting(cloud).filter { !excluded.contains($0.id) }
        guard !targets.isEmpty else { return }
        let added = addToICloud(targets)
        guard !added.isEmpty else { return }
        recordSent(added)
        autoUploadedIDs.formUnion(added.map(\.id))
        logger.notice("event=autoUpload count=\(added.count, privacy: .public)")
    }

    /// 退避された地点のうち、現在のアカウントでこの端末が送ったものを記録から外し、再び自動追加の対象にする。
    /// 退避されたのは初回同期前の書き込みを OS が破棄したため。観測しただけの地点や、前のアカウントで送った地点は外さない
    /// （accountChange の後の初回同期で退避されても、新しいアカウントには送らず、設定画面の候補に出す）。
    private func forgetSent(_ evacuated: [FavoriteLocation]) {
        let ids = sentIDsCurrentAccount.intersection(evacuated.map(\.id))
        guard !ids.isEmpty else { return }
        sentIDs.subtract(ids)
        sentIDsCurrentAccount.subtract(ids)
        observedIDs.subtract(ids)
        saveIDs(sentIDs, forKey: Self.sentIDsKey)
        saveIDs(sentIDsCurrentAccount, forKey: Self.sentIDsCurrentAccountKey)
        saveIDs(observedIDs, forKey: Self.observedIDsKey)
    }

    private func resetSentForCurrentAccount() {
        sentIDsCurrentAccount = []
        saveIDs(sentIDsCurrentAccount, forKey: Self.sentIDsCurrentAccountKey)
    }

    /// 稼働中の iCloud ストアの一覧を左辺にした和集合を、削除反映の基準を進めずに保存する。
    /// 実際に加わった地点を返す（重複したときはストア側が残る。KV に書けなかったときは空）。
    private func addToICloud(_ selected: [FavoriteLocation]) -> [FavoriteLocation] {
        guard let iCloudStore else { return [] }
        let current = iCloudStore.loadAll()
        let merged = current.unionPreservingOrder(selected)
        guard merged.count > current.count else { return [] }
        // 上限を超える一覧を save すると、KV に届かないまま表示中の一覧だけが膨らみ、
        // その後の利用者の編集も KV に書かれなくなる。送れないときは一覧を変えない。
        guard iCloudFavoriteLocationStore.fitsInKVStore(merged) else {
            logger.warning("event=autoUploadSkipped reason=sizeLimit count=\(selected.count, privacy: .public)")
            return []
        }
        iCloudStore.save(merged, advancingDeletionBaseline: false)
        // encode に失敗したときや、60KB を超えて KV に書かずに fallback へ回ったときは、送っていないので記録も通知もしない。
        guard iCloudFavoriteLocationStore.loadFromKVStore(kvStore) == merged else { return [] }
        return Array(merged[current.count...])
    }

    private func recordSent(_ added: [FavoriteLocation]) {
        guard !added.isEmpty else { return }
        sentIDs.formUnion(added.map(\.id))
        sentIDsCurrentAccount.formUnion(added.map(\.id))
        saveIDs(sentIDs, forKey: Self.sentIDsKey)
        saveIDs(sentIDsCurrentAccount, forKey: Self.sentIDsCurrentAccountKey)
    }

    private func recomputeLocalOnly(active: [FavoriteLocation]) {
        localOnly = FavoriteLocationStore.loadFavorites(userDefaults: localDefaults).subtracting(active)
    }

    private static func loadIDs(_ defaults: UserDefaults, forKey key: String) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func saveIDs(_ ids: Set<UUID>, forKey key: String) {
        localDefaults.set(ids.map(\.uuidString), forKey: key)
    }
}
