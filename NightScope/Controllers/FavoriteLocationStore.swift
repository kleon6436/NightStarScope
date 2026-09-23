import Foundation
import os
import Combine

private let logger = Logger(subsystem: "com.nightscope", category: "FavoriteLocationStore")

/// 保存済み地点の永続化と読込を抽象化する。
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
            let data = try JSONEncoder().encode(favorites)
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
            return try JSONDecoder().decode([FavoriteLocation].self, from: data)
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
    /// KV ストアの実用上限（Apple の 64KB 制限に対して余裕を持たせる）
    private static let maxDataSize = 60 * 1_024

    // MARK: - State

    @Published private(set) var locations: [FavoriteLocation]
    /// 直前の `save` に渡した一覧（起動時は読み込んだ一覧）。永続化しない。
    /// 削除の反映の対象を「この端末で削除した地点」に限るために使う。
    private var lastSavedSnapshot: [FavoriteLocation]
    private let kvStore: any UbiquitousKeyValueStoring
    /// フォールバックの保存先。あわせて、退避と削除の反映でこの端末のお気に入り（`FavoriteLocationStore.storageKey`）を書き換える。
    private let fallbackDefaults: UserDefaults
    private let notificationCenter: NotificationCenter

    // MARK: - Init

    init(kvStore: any UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default,
         fallbackDefaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default) {
        self.kvStore = kvStore
        self.fallbackDefaults = fallbackDefaults
        self.notificationCenter = notificationCenter
        let kvReadStart = ContinuousClock.now
        let kvLocations = Self.loadFromKVStore(kvStore)
        let kvReadMs = Int((ContinuousClock.now - kvReadStart) / .milliseconds(1))
        let initialLocations = kvLocations ?? Self.loadFromFallback(fallbackDefaults)
        self.locations = initialLocations
        self.lastSavedSnapshot = initialLocations

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

    func save(_ favorites: [FavoriteLocation]) {
        do {
            let data = try JSONEncoder().encode(favorites)
            reflectDeletionToLocal(newFavorites: favorites)
            if data.count > Self.maxDataSize {
                iCloudLogger.warning(
                    "Favorites data (\(data.count) bytes) exceeds 60 KB limit; skipping iCloud write."
                )
                // サイズ超過時はローカル UserDefaults のみ更新する
                fallbackDefaults.set(data, forKey: Self.localFallbackKey)
            } else {
                kvStore.set(data, forKey: Self.iCloudKey)
                kvStore.synchronize()
            }
            locations = favorites
            lastSavedSnapshot = favorites
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
            let newLocations = Self.loadFromKVStore(kvStore) ?? []
            let lost = locations.subtracting(newLocations)
            if !lost.isEmpty {
                let local = FavoriteLocationStore.loadFavorites(userDefaults: fallbackDefaults)
                writeLocalFavorites(local.unionPreservingOrder(lost))
                iCloudLogger.notice(
                    "event=evacuate reason=\(reasonValue ?? -1, privacy: .public) count=\(lost.count, privacy: .public)"
                )
            }
            applyExternalLocations(newLocations)
        case .accountChange:
            // アカウントの境界を越えてデータを移さないため、退避も統合もせず KV をそのまま反映する。
            // 新しいアカウントに対象キーがなくても前のアカウントの一覧を残さないよう、changedKeys に関係なく KV を読み直す。
            applyExternalLocations(Self.loadFromKVStore(kvStore) ?? [])
        case .quotaViolationChange:
            iCloudLogger.warning("iCloud KVStore quota exceeded; favorites may not be synced.")
        case .serverChange, nil:
            guard hasKey, let updated = Self.loadFromKVStore(kvStore) else { return }
            applyExternalLocations(updated)
        }
    }

    /// 外部から届いた一覧を反映する。
    /// `lastSavedSnapshot` からは届いた一覧にない地点を外す。他の端末で削除された地点や初回同期で破棄された地点を、
    /// 次の save で「この端末で削除した」とみなしてローカルから消さないため。届いた地点は加えない。
    private func applyExternalLocations(_ newLocations: [FavoriteLocation]) {
        lastSavedSnapshot = lastSavedSnapshot.filter { saved in newLocations.contains { saved.isSameSpot(as: $0) } }
        locations = newLocations
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

    private func writeLocalFavorites(_ favorites: [FavoriteLocation]) {
        do {
            let data = try JSONEncoder().encode(favorites)
            fallbackDefaults.set(data, forKey: FavoriteLocationStore.storageKey)
        } catch {
            iCloudLogger.error("Failed to encode local favorites: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// KV ストアのお気に入りを読み込む。キーがないかデコードに失敗したときは nil を返す。
    static func loadFromKVStore(_ kvStore: any UbiquitousKeyValueStoring) -> [FavoriteLocation]? {
        guard let data = kvStore.data(forKey: iCloudKey) else { return nil }
        do {
            return try JSONDecoder().decode([FavoriteLocation].self, from: data)
        } catch {
            iCloudLogger.error("Failed to decode favorites from iCloud KVStore: \(error)")
            return nil
        }
    }

    private static func loadFromFallback(_ defaults: UserDefaults) -> [FavoriteLocation] {
        guard let data = defaults.data(forKey: localFallbackKey) else { return [] }
        do {
            return try JSONDecoder().decode([FavoriteLocation].self, from: data)
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
