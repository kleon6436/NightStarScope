import Foundation
import os
import Combine

private let logger = Logger(subsystem: "com.nightscope", category: "FavoriteLocationStore")

/// お気に入り一覧の JSON 変換（UserDefaults / iCloud KV の両実装で共有）。
private enum FavoriteLocationCodec {
    static func encode(_ favorites: [FavoriteLocation]) throws -> Data {
        try JSONEncoder().encode(favorites)
    }

    static func decode(_ data: Data) throws -> [FavoriteLocation] {
        try JSONDecoder().decode([FavoriteLocation].self, from: data)
    }
}

/// 保存済み地点の永続化と読込を抽象化する。
/// - Important: `locationsPublisher` の購読者は `receive(on: DispatchQueue.main)` で受け取ること。
///   `iCloudFavoriteLocationStore` は reconciler が加えた地点を削除反映の基準に入れるのをメインキューの次のターンまで遅らせ、
///   購読者への配信がそれより先に届く（FIFO）ことに依存している。
protocol FavoriteLocationStoring: AnyObject, Sendable {
    var locationsPublisher: AnyPublisher<[FavoriteLocation], Never> { get }
    func loadAll() -> [FavoriteLocation]
    func save(_ favorites: [FavoriteLocation])
}

extension FavoriteLocationStoring {
    var locationsPublisher: AnyPublisher<[FavoriteLocation], Never> {
        Just(loadAll()).eraseToAnyPublisher()
    }
}

// UserDefaults はスレッドセーフ（Apple ドキュメント保証）なため @unchecked Sendable が安全。
// 変更可能な内部状態への直接アクセスは持たない。
/// UserDefaults に保存済み地点を保持する実装。
final class FavoriteLocationStore: ObservableObject, FavoriteLocationStoring, @unchecked Sendable {
    /// この端末のお気に入りを保存する UserDefaults のキー。
    static let storageKey = "favorites.locations"
    private let userDefaults: UserDefaults
    @Published private(set) var locations: [FavoriteLocation]

    /// 既存の保存データを復元して初期化する。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.locations = Self.loadFavorites(userDefaults: userDefaults)
    }

    /// 現在の保存済み地点を返す。
    func loadAll() -> [FavoriteLocation] {
        locations
    }

    var locationsPublisher: AnyPublisher<[FavoriteLocation], Never> {
        $locations.eraseToAnyPublisher()
    }

    /// 保存済み地点を JSON で永続化する。
    func save(_ favorites: [FavoriteLocation]) {
        do {
            let data = try FavoriteLocationCodec.encode(favorites)
            userDefaults.set(data, forKey: Self.storageKey)
            locations = favorites
        } catch {
            logger.error("Failed to encode favorites: \(error)")
        }
    }

    /// この端末のお気に入りを UserDefaults から読み込む。
    static func loadFavorites(userDefaults: UserDefaults) -> [FavoriteLocation] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [] }
        do {
            return try FavoriteLocationCodec.decode(data)
        } catch {
            logger.error("Failed to decode favorites: \(error)")
            return []
        }
    }
}

// MARK: - iCloudFavoriteLocationStore

private let iCloudLogger = Logger(subsystem: "com.nightscope", category: "iCloudFavoriteLocationStore")

/// お気に入り同期で使う iCloud KV ストアの操作を抽象化する（テストでフェイクを注入するため）。
protocol UbiquitousKeyValueStoring: AnyObject {
    func data(forKey aKey: String) -> Data?
    func set(_ aData: Data?, forKey aKey: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

/// NSUbiquitousKeyValueStore を使って iCloud にお気に入り地点を同期する実装。
/// iCloud が利用不可のときは UserDefaults にフォールバックする。
@MainActor
final class iCloudFavoriteLocationStore: ObservableObject, @preconcurrency FavoriteLocationStoring {
    // MARK: - Constants

    nonisolated static let iCloudKey = "favorites.locations.v1"
    private static let localFallbackKey = "favorites.locations.icloud.fallback"
    /// fallback に KV より新しい一覧がある（60KB 超過で KV に書けなかった）ことを示すフラグのキー。
    static let fallbackIsNewerKey = "favorites.locations.icloud.fallbackIsNewer"
    /// この端末での追加・削除を、届いた一覧で確認できるまで保留として扱う時間。
    /// 他の端末がこの変更を見る前に書いた一覧（同時編集）で失われないよう、この間は届いた一覧に統合し直す。
    static let pendingChangeWindow: TimeInterval = 10 * 60
    /// KV ストアの実用上限（Apple の 64KB 制限に対して余裕を持たせる）
    private static let maxDataSize = 60 * 1_024

    /// 一覧が KV の実用上限に収まるかを返す。収まらない一覧を save すると KV に書かれず fallback に回る。
    static func fitsInKVStore(_ favorites: [FavoriteLocation]) -> Bool {
        guard let data = try? FavoriteLocationCodec.encode(favorites) else { return false }
        return data.count <= maxDataSize
    }

    // MARK: - State

    @Published private(set) var locations: [FavoriteLocation]
    /// 直前の `save` に渡した一覧（起動時は読み込んだ一覧）。永続化しない。
    /// 削除の反映の対象を「この端末で削除した地点」に限るために使う。
    private var lastSavedSnapshot: [FavoriteLocation]
    private let kvStore: any UbiquitousKeyValueStoring
    /// フォールバックの保存先。あわせて、退避と削除の反映でこの端末のお気に入り（`FavoriteLocationStore.storageKey`）を書き換える。
    private let fallbackDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let evacuatedSubject = PassthroughSubject<[FavoriteLocation], Never>()
    private let accountChangedSubject = PassthroughSubject<Void, Never>()
    private let now: () -> Date
    /// この端末で追加し、まだ届いた一覧で確認できていない地点の ID と追加時刻。永続化しない。
    private var pendingAdds: [UUID: Date] = [:]
    /// この端末で削除し、まだ届いた一覧で確認できていない地点の ID と削除時刻。永続化しない。
    private var pendingDeletes: [UUID: Date] = [:]
    /// KV のデータがデコードできない。デコードできるデータが届くまで KV に書かない（他の端末のデータを壊さない）。
    private var isKVDataUnreadable = false

    /// KV の読み出し結果。キーがない場合とデコードできない場合を区別する。
    private enum KVReadResult {
        case missing
        case decoded([FavoriteLocation])
        case undecodable
    }

    // MARK: - Init

    init(kvStore: any UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default,
         fallbackDefaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default,
         now: @escaping () -> Date = { Date() }) {
        self.kvStore = kvStore
        self.fallbackDefaults = fallbackDefaults
        self.notificationCenter = notificationCenter
        self.now = now
        let kvReadStart = ContinuousClock.now
        let kvRead = Self.readKV(kvStore)
        let kvReadMs = Int((ContinuousClock.now - kvReadStart) / .milliseconds(1))
        // 60KB 超過で fallback にだけ保存した一覧は KV より新しいので優先する（KV を読むと編集が巻き戻る）。
        let fallbackIsNewer = fallbackDefaults.bool(forKey: Self.fallbackIsNewerKey)
            && fallbackDefaults.data(forKey: Self.localFallbackKey) != nil
        let kvLocations: [FavoriteLocation]?
        let isKVDataUnreadable: Bool
        switch kvRead {
        case .decoded(let decoded):
            kvLocations = fallbackIsNewer ? nil : decoded
            isKVDataUnreadable = false
        case .missing:
            kvLocations = nil
            isKVDataUnreadable = false
        case .undecodable:
            // 壊れたデータは上書きせずに残し、表示はこの端末の fallback で行う。
            kvLocations = nil
            isKVDataUnreadable = true
        }
        let initialLocations = kvLocations ?? Self.loadFromFallback(fallbackDefaults)
        self.locations = initialLocations
        self.lastSavedSnapshot = initialLocations
        self.isKVDataUnreadable = isKVDataUnreadable

        notificationCenter.addObserver(
            self,
            selector: #selector(kvStoreDidChangeExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        let syncStart = ContinuousClock.now
        kvStore.synchronize()
        let syncMs = Int((ContinuousClock.now - syncStart) / .milliseconds(1))
        iCloudLogger.notice(
            "event=storeInit source=\(kvLocations == nil ? "fallback" : "kv", privacy: .public) count=\(self.locations.count, privacy: .public) kvReadMs=\(kvReadMs, privacy: .public) syncMs=\(syncMs, privacy: .public)"
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    // MARK: - FavoriteLocationStoring

    var locationsPublisher: AnyPublisher<[FavoriteLocation], Never> {
        $locations.eraseToAnyPublisher()
    }

    func loadAll() -> [FavoriteLocation] {
        locations
    }

    /// initialSyncChange でローカルへ退避した地点を流す。ローカルへ書き終えた後、`locations` を更新する前に流れる。
    var evacuatedPublisher: AnyPublisher<[FavoriteLocation], Never> {
        evacuatedSubject.eraseToAnyPublisher()
    }

    /// accountChange を受けたことを流す。`locations` を新しいアカウントの一覧に更新する前に流れる。
    var accountChangedPublisher: AnyPublisher<Void, Never> {
        accountChangedSubject.eraseToAnyPublisher()
    }

    func save(_ favorites: [FavoriteLocation]) {
        save(favorites, advancingDeletionBaseline: true)
    }

    /// `advancingDeletionBaseline` が false のときは削除の反映をせず、`lastSavedSnapshot` もその場では進めない。
    /// reconciler が地点を加えるときに使う。ViewModel は `receive(on: DispatchQueue.main)` で次のターンに追いつくので、
    /// それまでに古い配列で save されても、加えた地点をこの端末のお気に入りからは消さない。
    /// 加えた地点はメインキューの次のターン（ViewModel への配信の後）で基準に入れ、その後の明示的な削除は通常どおり反映する。
    func save(_ favorites: [FavoriteLocation], advancingDeletionBaseline: Bool) {
        do {
            let data = try FavoriteLocationCodec.encode(favorites)
            let added = favorites.subtracting(locations)
            if advancingDeletionBaseline {
                recordPendingChanges(newFavorites: favorites)
                reflectDeletionToLocal(newFavorites: favorites)
            }
            persist(data)
            locations = favorites
            if advancingDeletionBaseline {
                lastSavedSnapshot = favorites
            } else if !added.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.admitToDeletionBaseline(added)
                }
            }
        } catch {
            iCloudLogger.error("Failed to encode favorites for iCloud: \(error)")
        }
    }

    // MARK: - External Change Notification

    @objc nonisolated private func kvStoreDidChangeExternally(_ notification: Notification) {
        // Notification はメインキュー配信が原則だが iOS では稀にバックグラウンドで届く。
        // @objc thunk の実行時隔離チェックで trap しないよう nonisolated で受け、Sendable な値だけを Task でメインへ渡す。
        let reasonValue = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        let hasKey = changedKeys?.contains(Self.iCloudKey) == true
        iCloudLogger.notice(
            "event=externalChange phase=entry reason=\(reasonValue ?? -1, privacy: .public) hasKey=\(hasKey ? 1 : 0, privacy: .public) isMain=\(Thread.isMainThread ? 1 : 0, privacy: .public)"
        )
        Task { @MainActor [weak self, reasonValue, hasKey] in
            guard let self else { return }
            applyExternalChange(reasonValue: reasonValue, hasKey: hasKey)
            iCloudLogger.notice(
                "event=externalChange phase=applied reason=\(reasonValue ?? -1, privacy: .public) count=\(self.locations.count, privacy: .public)"
            )
        }
    }

    /// 外部変更を reason 別に反映する。
    private func applyExternalChange(reasonValue: Int?, hasKey: Bool) {
        let reason = reasonValue.flatMap { NSUbiquitousKeyValueStore.ChangeReason(rawValue: $0) }
        iCloudLogger.debug("iCloud KVStore changed externally (reason: \(String(describing: reason)))")
        switch reason {
        case .initialSyncChange:
            // 初回同期前の書き込みは OS に破棄されるため、changedKeys に関係なく KV を読み直し、
            // 消える地点をローカルへ退避してから反映する（reconciler が退避分を必ず拾える順序）。
            // 破棄された書き込みは同時編集ではないので、保留中の変更は統合し直さない。
            clearPendingChanges()
            guard let newLocations = decodedLocations(Self.readKV(kvStore), missingAs: []) else { return }
            let lost = locations.subtracting(newLocations)
            if !lost.isEmpty {
                let local = FavoriteLocationStore.loadFavorites(userDefaults: fallbackDefaults)
                writeLocalFavorites(local.unionPreservingOrder(lost))
                iCloudLogger.notice(
                    "event=evacuate reason=\(reasonValue ?? -1, privacy: .public) count=\(lost.count, privacy: .public)"
                )
                evacuatedSubject.send(lost)
            }
            applyExternalLocations(newLocations)
        case .accountChange:
            // アカウントの境界を越えてデータを移さないため、退避も統合もせず KV をそのまま反映する。
            // 新しいアカウントに対象キーがなくても前のアカウントの一覧を残さないよう、changedKeys に関係なく KV を読み直す。
            accountChangedSubject.send()
            clearPendingChanges()
            applyExternalLocations(decodedLocations(Self.readKV(kvStore), missingAs: []) ?? [])
        case .quotaViolationChange:
            iCloudLogger.warning("iCloud KVStore quota exceeded; favorites may not be synced.")
        case .serverChange, nil:
            guard hasKey, let remote = decodedLocations(Self.readKV(kvStore), missingAs: nil) else { return }
            applyServerChange(remote)
        }
    }

    /// 他の端末からの一覧を、この端末の未確認の変更と三方向で統合して反映する。
    /// 結果 = 届いた一覧 − この端末で削除した地点 ∪ この端末で追加した地点（どちらも未確認かつ保留期間内のもの）。
    /// 届いた一覧と異なれば KV に書き戻す。60KB 超過で fallback の方が新しいときは、この端末の一覧をすべて残す。
    private func applyServerChange(_ remote: [FavoriteLocation]) {
        let timestamp = now()
        let remoteIDs = Set(remote.map(\.id))
        // 届いた一覧で確認できた変更と、保留期間を過ぎた変更は保留から外す。
        pendingAdds = pendingAdds.filter { id, addedAt in
            !remoteIDs.contains(id) && timestamp.timeIntervalSince(addedAt) < Self.pendingChangeWindow
        }
        pendingDeletes = pendingDeletes.filter { id, deletedAt in
            remoteIDs.contains(id) && timestamp.timeIntervalSince(deletedAt) < Self.pendingChangeWindow
        }
        let keepsAllLocal = fallbackDefaults.bool(forKey: Self.fallbackIsNewerKey)
        let preserved = locations.filter { keepsAllLocal || pendingAdds[$0.id] != nil }
        let merged = remote
            .filter { pendingDeletes[$0.id] == nil }
            .unionPreservingOrder(preserved)
        if merged != remote {
            do {
                let data = try FavoriteLocationCodec.encode(merged)
                persist(data)
                iCloudLogger.notice(
                    "event=mergeServerChange remote=\(remote.count, privacy: .public) merged=\(merged.count, privacy: .public)"
                )
            } catch {
                iCloudLogger.error("Failed to encode merged favorites: \(error)")
            }
        }
        applyExternalLocations(merged)
    }

    /// 外部から届いた一覧を反映する。
    /// `lastSavedSnapshot` からは届いた一覧にない地点を外す。他の端末で削除された地点や初回同期で破棄された地点を、
    /// 次の save で「この端末で削除した」とみなしてローカルから消さないため。届いた地点は加えない。
    private func applyExternalLocations(_ newLocations: [FavoriteLocation]) {
        lastSavedSnapshot = lastSavedSnapshot.filter { saved in newLocations.contains { saved.isSameSpot(as: $0) } }
        locations = newLocations
    }

    // MARK: - Pending Changes / Persistence

    /// この端末での追加・削除を、届いた一覧で確認できるまで保留として記録する。
    /// 削除は `reflectDeletionToLocal` と同じく直前の save にあった地点に限る（古い配列での save を削除とみなさない）。
    private func recordPendingChanges(newFavorites: [FavoriteLocation]) {
        let timestamp = now()
        let previousIDs = Set(locations.map(\.id))
        for favorite in newFavorites where !previousIDs.contains(favorite.id) {
            pendingAdds[favorite.id] = timestamp
            pendingDeletes[favorite.id] = nil
        }
        let newIDs = Set(newFavorites.map(\.id))
        for removed in lastSavedSnapshot where !newIDs.contains(removed.id) {
            pendingDeletes[removed.id] = timestamp
            pendingAdds[removed.id] = nil
        }
    }

    private func clearPendingChanges() {
        pendingAdds = [:]
        pendingDeletes = [:]
    }

    /// 一覧のデータを KV（書けないときは fallback）に保存する。
    /// KV のデータがデコードできない間は上書きしない。60KB を超えるときは fallback に保存し、fallback の方が新しいと記録する。
    private func persist(_ data: Data) {
        if isKVDataUnreadable {
            if case .undecodable = Self.readKV(kvStore) {
                iCloudLogger.warning("iCloud favorites data is unreadable; skipping iCloud write to preserve it.")
                fallbackDefaults.set(data, forKey: Self.localFallbackKey)
                return
            }
            isKVDataUnreadable = false
        }
        if data.count > Self.maxDataSize {
            iCloudLogger.warning(
                "Favorites data (\(data.count) bytes) exceeds 60 KB limit; skipping iCloud write."
            )
            // サイズ超過時はローカル UserDefaults のみ更新し、次回起動時に KV より優先させる
            fallbackDefaults.set(data, forKey: Self.localFallbackKey)
            fallbackDefaults.set(true, forKey: Self.fallbackIsNewerKey)
        } else {
            kvStore.set(data, forKey: Self.iCloudKey)
            kvStore.synchronize()
            fallbackDefaults.removeObject(forKey: Self.fallbackIsNewerKey)
        }
    }

    /// 読み出し結果を一覧に変換する。デコードできないときは記録して nil を返す（呼び出し側は反映しない）。
    private func decodedLocations(_ result: KVReadResult, missingAs missingValue: [FavoriteLocation]?) -> [FavoriteLocation]? {
        switch result {
        case .decoded(let decoded):
            isKVDataUnreadable = false
            return decoded
        case .missing:
            return missingValue
        case .undecodable:
            isKVDataUnreadable = true
            return nil
        }
    }

    // MARK: - Local Writes（退避と削除の反映のみ）

    /// iCloud モードの save で消えた地点を、この端末のお気に入りからも取り除く。
    /// 対象は直前の save の時点で存在した地点に限る（古い配列のまま save されても、その間に届いた地点は消さない）。
    private func reflectDeletionToLocal(newFavorites: [FavoriteLocation]) {
        let removed = lastSavedSnapshot.subtracting(newFavorites)
        guard !removed.isEmpty else { return }
        let local = FavoriteLocationStore.loadFavorites(userDefaults: fallbackDefaults)
        let pruned = local.subtracting(removed)
        guard pruned.count != local.count else { return }
        writeLocalFavorites(pruned)
        iCloudLogger.notice("event=localPrune count=\(local.count - pruned.count, privacy: .public)")
    }

    /// reconciler が加えた地点のうち、まだ一覧に残っているものだけを削除反映の基準に加える。
    /// 基準に地点を加えるのはこの経路だけ（それ以外は save で置き換えるか、届いた一覧との共通部分に絞る）。
    private func admitToDeletionBaseline(_ added: [FavoriteLocation]) {
        let remaining = added.filter { spot in locations.contains { spot.isSameSpot(as: $0) } }
        lastSavedSnapshot = lastSavedSnapshot.unionPreservingOrder(remaining)
    }

    private func writeLocalFavorites(_ favorites: [FavoriteLocation]) {
        do {
            let data = try FavoriteLocationCodec.encode(favorites)
            fallbackDefaults.set(data, forKey: FavoriteLocationStore.storageKey)
        } catch {
            iCloudLogger.error("Failed to encode local favorites: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// KV ストアのお気に入りを読み込む。キーがないかデコードに失敗したときは nil を返す。
    static func loadFromKVStore(_ kvStore: any UbiquitousKeyValueStoring) -> [FavoriteLocation]? {
        if case .decoded(let decoded) = readKV(kvStore) {
            return decoded
        }
        return nil
    }

    private static func readKV(_ kvStore: any UbiquitousKeyValueStoring) -> KVReadResult {
        guard let data = kvStore.data(forKey: iCloudKey) else { return .missing }
        do {
            return .decoded(try FavoriteLocationCodec.decode(data))
        } catch {
            iCloudLogger.error("Failed to decode favorites from iCloud KVStore: \(error)")
            return .undecodable
        }
    }

    private static func loadFromFallback(_ defaults: UserDefaults) -> [FavoriteLocation] {
        guard let data = defaults.data(forKey: localFallbackKey) else { return [] }
        do {
            return try FavoriteLocationCodec.decode(data)
        } catch {
            iCloudLogger.error("Failed to decode favorites from fallback UserDefaults: \(error)")
            return []
        }
    }
}

// MARK: - NSUbiquitousKeyValueStore.ChangeReason

private extension NSUbiquitousKeyValueStore {
    enum ChangeReason: Int {
        case serverChange = 0
        case initialSyncChange = 1
        case quotaViolationChange = 2
        case accountChange = 3
    }
}
