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

// MARK: - FavoriteDeletionLedger

/// お気に入りの削除の記録（tombstone）と、削除済みの地点を加え直した記録（復活）。
/// 一覧のキー（旧バージョンが読む）とは別の iCloud KV キーに保存し、端末間では ID ごとに新しい時刻を採って統合する。
/// 地点は「削除の時刻が復活の時刻より新しい」ときに削除済みとみなす。
/// - Note: 時刻は 1970 年からの秒数。キーは `UUID.uuidString`。
struct FavoriteDeletionLedger: Codable, Equatable, Sendable {
    /// 記録を残す期間。これより古い記録は捨てる（それより長く同期しなかった端末の古い一覧では削除が戻りうる）。
    static let retention: TimeInterval = 60 * 24 * 60 * 60
    /// 残す記録の最大件数（削除と復活の合計）。超えた分は古い順に捨てる。
    static let maxEntries = 800
    /// エンコード後の最大サイズ。KV の 1 キーあたり・全体の上限に対して十分に小さくする。
    static let maxEncodedSize = 60 * 1_024
    /// 同じ端末の中で削除と復活の前後関係を保つため、直前の記録より後ろにずらす幅（秒）。
    private static let orderingEpsilon: TimeInterval = 0.001

    private(set) var deletedAt: [String: TimeInterval] = [:]
    private(set) var revivedAt: [String: TimeInterval] = [:]

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case deletedAt = "deleted"
        case revivedAt = "revived"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deletedAt = try container.decodeIfPresent([String: TimeInterval].self, forKey: .deletedAt) ?? [:]
        revivedAt = try container.decodeIfPresent([String: TimeInterval].self, forKey: .revivedAt) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(revivedAt, forKey: .revivedAt)
    }

    var isEmpty: Bool {
        deletedAt.isEmpty && revivedAt.isEmpty
    }

    /// 削除済み（削除の記録が復活の記録より新しい）かどうかを返す。
    func isDeleted(_ id: UUID) -> Bool {
        let key = id.uuidString
        guard let deleted = deletedAt[key] else { return false }
        guard let revived = revivedAt[key] else { return true }
        return deleted > revived
    }

    /// 削除を記録する。この端末の時計が遅れていても、知っている復活より後になるようにする。
    mutating func recordDeletion(of id: UUID, at date: Date) {
        let key = id.uuidString
        var timestamp = date.timeIntervalSince1970
        if let revived = revivedAt[key] {
            timestamp = max(timestamp, revived + Self.orderingEpsilon)
        }
        deletedAt[key] = max(deletedAt[key] ?? timestamp, timestamp)
    }

    /// 削除済みの地点を加え直したことを記録する。削除済みでない地点では何もしない（記録を増やさない）。
    mutating func recordRevival(of id: UUID, at date: Date) {
        let key = id.uuidString
        guard isDeleted(id), let deleted = deletedAt[key] else { return }
        let timestamp = max(date.timeIntervalSince1970, deleted + Self.orderingEpsilon)
        revivedAt[key] = max(revivedAt[key] ?? timestamp, timestamp)
    }

    /// ID ごとに新しい方の時刻を採って統合する。
    func merging(_ other: FavoriteDeletionLedger) -> FavoriteDeletionLedger {
        var result = self
        result.deletedAt.merge(other.deletedAt) { max($0, $1) }
        result.revivedAt.merge(other.revivedAt) { max($0, $1) }
        return result
    }

    /// 保持期間を過ぎた記録を捨て、件数とサイズを上限に収める（新しい記録を優先して残す）。
    func pruned(now: Date) -> FavoriteDeletionLedger {
        let cutoff = now.timeIntervalSince1970 - Self.retention
        var result = self
        result.deletedAt = result.deletedAt.filter { $0.value >= cutoff }
        result.revivedAt = result.revivedAt.filter { $0.value >= cutoff }
        var limit = Self.maxEntries
        while true {
            result = result.keepingNewest(limit)
            let size = (try? JSONEncoder().encode(result).count) ?? 0
            if size <= Self.maxEncodedSize || limit == 0 {
                return result
            }
            limit = min(limit, result.deletedAt.count + result.revivedAt.count) * 3 / 4
        }
    }

    private func keepingNewest(_ limit: Int) -> FavoriteDeletionLedger {
        guard deletedAt.count + revivedAt.count > limit else { return self }
        typealias Entry = (key: String, time: TimeInterval, isDeletion: Bool)
        let deletions: [Entry] = deletedAt.map { (key: $0.key, time: $0.value, isDeletion: true) }
        let revivals: [Entry] = revivedAt.map { (key: $0.key, time: $0.value, isDeletion: false) }
        let entries = deletions + revivals
        let kept = entries.sorted { $0.time > $1.time }.prefix(limit)
        var result = FavoriteDeletionLedger()
        for entry in kept {
            if entry.isDeletion {
                result.deletedAt[entry.key] = entry.time
            } else {
                result.revivedAt[entry.key] = entry.time
            }
        }
        return result
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

    /// お気に入り一覧のキー。形式は変えない（旧バージョンはこのキーだけを読み書きする）。
    nonisolated static let iCloudKey = "favorites.locations.v1"
    /// 削除の記録（`FavoriteDeletionLedger`）を保存する iCloud KV のキー。旧バージョンは読まない。
    nonisolated static let deletionLedgerKey = "favorites.deletions.v1"
    private static let localFallbackKey = "favorites.locations.icloud.fallback"
    /// fallback に KV より新しい一覧がある（60KB 超過で KV に書けなかった）ことを示すフラグのキー。
    static let fallbackIsNewerKey = "favorites.locations.icloud.fallbackIsNewer"
    /// この端末で追加し、まだ届いた一覧で確認できていない地点の ID を保存するキー（端末ローカル、再起動をまたいで保持）。
    static let pendingAddIDsKey = "favorites.sync.pendingAddIDs"
    /// この端末が知っている削除の記録を保存するキー（端末ローカル）。KV の記録が他の端末の値で置き換わっても失わないため。
    static let localDeletionLedgerKey = "favorites.sync.deletionLedger"
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
    /// 画面に届いている地点の ID。save でここから消えた地点を、この端末での削除として記録する（tombstone）。
    /// `lastSavedSnapshot` と違い、他の端末から届いた地点も含む（他の端末で加えた地点の削除も伝えるため）。
    /// 届いた地点と reconciler が加えた地点はメインキューの次のターン（ViewModel への配信の後）で加え、
    /// それまでの古い配列での save を削除とみなさない。
    private var tombstoneBaselineIDs: Set<UUID>
    /// 届いた一覧で消えた地点のうち、まだ画面に届いていない（ViewModel が古い配列を持っているかもしれない）ものの ID。
    /// その間の save に含まれていても、この端末での追加（復活・未確認の追加）とはみなさない。
    private var removedAwaitingViewIDs: Set<UUID> = []
    private let kvStore: any UbiquitousKeyValueStoring
    /// フォールバックの保存先。あわせて、退避と削除の反映でこの端末のお気に入り（`FavoriteLocationStore.storageKey`）を書き換える。
    private let fallbackDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let evacuatedSubject = PassthroughSubject<[FavoriteLocation], Never>()
    private let accountChangedSubject = PassthroughSubject<Void, Never>()
    private let now: () -> Date
    /// この端末で追加し、まだ届いた一覧で確認できていない地点の ID。`pendingAddIDsKey` に永続化する。
    /// 届いた一覧にないとき、他の端末がまだ見ていない追加として残す（他の端末で削除されたとはみなさない）。
    private var pendingAddIDs: Set<UUID>
    /// この端末が知っている削除の記録。`localDeletionLedgerKey` に永続化し、KV の `deletionLedgerKey` にも書く。
    private var deletionLedger: FavoriteDeletionLedger
    /// KV のデータがデコードできない。デコードできるデータが届くまで KV に書かない（他の端末のデータを壊さない）。
    private var isKVDataUnreadable = false

    /// KV の読み出し結果。キーがない場合とデコードできない場合を区別する。
    private enum KVReadResult {
        case missing
        case decoded([FavoriteLocation])
        case undecodable
    }

    /// 削除の記録の読み出し結果。
    private enum LedgerReadResult {
        case missing
        case decoded(FavoriteDeletionLedger)
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
        self.tombstoneBaselineIDs = Set(initialLocations.map(\.id))
        self.isKVDataUnreadable = isKVDataUnreadable
        // 前回の起動までの未確認の追加と削除の記録を引き継ぐ（オフラインの編集を再起動で失わない）。
        self.pendingAddIDs = Self.loadPendingAddIDs(fallbackDefaults)
            .intersection(initialLocations.map(\.id))
        let storedLedger = Self.loadLocalDeletionLedger(fallbackDefaults)
        var ledger = storedLedger
        if case .decoded(let remoteLedger) = Self.readLedger(kvStore) {
            ledger = ledger.merging(remoteLedger)
        }
        ledger = ledger.pruned(now: now())
        self.deletionLedger = ledger
        if ledger != storedLedger {
            Self.storeLocalDeletionLedger(ledger, to: fallbackDefaults)
        }

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
            let ledgerChanged = recordLocalChanges(
                newFavorites: favorites,
                advancingDeletionBaseline: advancingDeletionBaseline
            )
            if advancingDeletionBaseline {
                reflectDeletionToLocal(newFavorites: favorites)
            }
            // 削除の記録を一覧より先に書く（一覧だけが先に届いた端末でも、続く記録で削除をやり直せる）。
            if ledgerChanged {
                writeDeletionLedgerToKV()
            }
            persist(data)
            locations = favorites
            if advancingDeletionBaseline {
                lastSavedSnapshot = favorites
                tombstoneBaselineIDs = Set(favorites.map(\.id))
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
        let hasLedgerKey = changedKeys?.contains(Self.deletionLedgerKey) == true
        iCloudLogger.notice(
            "event=externalChange phase=entry reason=\(reasonValue ?? -1, privacy: .public) hasKey=\(hasKey ? 1 : 0, privacy: .public) hasLedgerKey=\(hasLedgerKey ? 1 : 0, privacy: .public) isMain=\(Thread.isMainThread ? 1 : 0, privacy: .public)"
        )
        Task { @MainActor [weak self, reasonValue, hasKey, hasLedgerKey] in
            guard let self else { return }
            applyExternalChange(reasonValue: reasonValue, hasKey: hasKey, hasLedgerKey: hasLedgerKey)
            iCloudLogger.notice(
                "event=externalChange phase=applied reason=\(reasonValue ?? -1, privacy: .public) count=\(self.locations.count, privacy: .public)"
            )
        }
    }

    /// 外部変更を reason 別に反映する。
    private func applyExternalChange(reasonValue: Int?, hasKey: Bool, hasLedgerKey: Bool) {
        let reason = reasonValue.flatMap { NSUbiquitousKeyValueStore.ChangeReason(rawValue: $0) }
        iCloudLogger.debug("iCloud KVStore changed externally (reason: \(String(describing: reason)))")
        switch reason {
        case .initialSyncChange:
            // 初回同期前の書き込みは OS に破棄されるため、changedKeys に関係なく KV を読み直し、
            // 消える地点をローカルへ退避してから反映する（reconciler が退避分を必ず拾える順序）。
            // 破棄された書き込みは同時編集ではないので、未確認の追加は統合し直さず、削除の記録もサーバーの値に揃える。
            resetLocalSyncState()
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
            // 前のアカウントの未確認の追加と削除の記録も持ち越さない。
            accountChangedSubject.send()
            resetLocalSyncState()
            applyExternalLocations(decodedLocations(Self.readKV(kvStore), missingAs: []) ?? [])
        case .quotaViolationChange:
            iCloudLogger.warning("iCloud KVStore quota exceeded; favorites may not be synced.")
        case .serverChange, nil:
            // 削除の記録だけが届いたときも、KV の一覧に記録を当て直す。
            guard hasKey || hasLedgerKey,
                  let remote = decodedLocations(Self.readKV(kvStore), missingAs: nil) else { return }
            applyServerChange(remote, listChanged: hasKey)
        }
    }

    /// 他の端末からの一覧を、この端末の未確認の追加と削除の記録で統合して反映する。
    /// 結果 = (届いた一覧 ∪ この端末で追加して未確認の地点) − 削除済みの地点。
    /// 削除の記録は両端末の記録を ID ごとに新しい方で統合したもの（どの端末の削除も伝わり、加え直しは復活の記録で上書きする）。
    /// 届いた一覧にない確認済みの地点は、他の端末で削除されたとみなす（削除の記録を書かない旧バージョンとの互換）。
    /// 一覧や記録が KV と異なれば書き戻す。60KB 超過で fallback の方が新しいときは、この端末の一覧をすべて残す。
    private func applyServerChange(_ remote: [FavoriteLocation], listChanged: Bool) {
        // KV の記録を取り込み、この端末だけが知っている記録があれば書き戻す。
        writeDeletionLedgerToKV()
        let ledger = deletionLedger
        var pending = pendingAddIDs
        // 他の端末が書いた一覧に含まれていた追加は確認済み（以後は、届いた一覧になければ削除として受け入れる）。
        // 記録だけが変わったときの KV の一覧はこの端末が書いたものかもしれないので、確認には使わない。
        if listChanged {
            pending.subtract(remote.map(\.id))
        }
        let keepsAllLocal = fallbackDefaults.bool(forKey: Self.fallbackIsNewerKey)
        let preserved = locations.filter { favorite in
            (keepsAllLocal || pending.contains(favorite.id)) && !ledger.isDeleted(favorite.id)
        }
        let merged = remote
            .filter { !ledger.isDeleted($0.id) }
            .unionPreservingOrder(preserved)
        // 一覧に残らなかった地点（削除済み、または同一地点として届いた地点に統合されたもの）は保留から外す。
        pending.formIntersection(merged.map(\.id))
        updatePendingAddIDs(pending)
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
        let newIDs = Set(newLocations.map(\.id))
        let removedIDs = Set(locations.map(\.id)).subtracting(newIDs)
        tombstoneBaselineIDs.formIntersection(newIDs)
        removedAwaitingViewIDs.formUnion(removedIDs)
        locations = newLocations
        DispatchQueue.main.async { [weak self] in
            self?.admitToTombstoneBaseline(newIDs)
            self?.removedAwaitingViewIDs.subtract(removedIDs)
        }
    }

    // MARK: - Pending Adds / Deletion Ledger

    /// 削除済みとして記録されている地点かどうかを返す。reconciler が削除済みの地点を自動で送り返さないために使う。
    func isMarkedDeleted(_ id: UUID) -> Bool {
        deletionLedger.isDeleted(id)
    }

    /// この端末での追加と削除を記録し、削除の記録が変わったら true を返す。
    /// 削除は画面に届いていた地点（`tombstoneBaselineIDs`）に限る（古い配列での save を削除とみなさない）。
    /// 追加した地点が削除済みなら復活として記録する（reconciler が加えた地点も含む）。
    /// 未確認の追加として残すのは、利用者の保存（`advancingDeletionBaseline` が true）で加えた地点だけ
    /// （reconciler が送った地点は、他の端末で削除されたら削除を受け入れる）。
    private func recordLocalChanges(newFavorites: [FavoriteLocation], advancingDeletionBaseline: Bool) -> Bool {
        let timestamp = now()
        let previousIDs = Set(locations.map(\.id))
        let newIDs = Set(newFavorites.map(\.id))
        var ledger = deletionLedger
        var pending = pendingAddIDs
        for favorite in newFavorites
        where !previousIDs.contains(favorite.id) && !removedAwaitingViewIDs.contains(favorite.id) {
            ledger.recordRevival(of: favorite.id, at: timestamp)
            if advancingDeletionBaseline {
                pending.insert(favorite.id)
            }
        }
        if advancingDeletionBaseline {
            for removedID in tombstoneBaselineIDs.subtracting(newIDs) {
                ledger.recordDeletion(of: removedID, at: timestamp)
            }
        }
        pending.formIntersection(newIDs)
        updatePendingAddIDs(pending)
        let previousLedger = deletionLedger
        updateDeletionLedger(ledger)
        return deletionLedger != previousLedger
    }

    /// 未確認の追加を捨て、削除の記録を KV の値（サーバーや新しいアカウントの値。なければ空）に置き換える。
    private func resetLocalSyncState() {
        updatePendingAddIDs([])
        if case .decoded(let kvLedger) = Self.readLedger(kvStore) {
            updateDeletionLedger(kvLedger)
        } else {
            updateDeletionLedger(FavoriteDeletionLedger())
        }
    }

    private func updatePendingAddIDs(_ ids: Set<UUID>) {
        guard ids != pendingAddIDs else { return }
        pendingAddIDs = ids
        fallbackDefaults.set(ids.map(\.uuidString), forKey: Self.pendingAddIDsKey)
    }

    /// 削除の記録を置き換え（保持期間と上限で刈り込む）、端末ローカルに保存する。
    private func updateDeletionLedger(_ ledger: FavoriteDeletionLedger) {
        let pruned = ledger.pruned(now: now())
        guard pruned != deletionLedger else { return }
        deletionLedger = pruned
        Self.storeLocalDeletionLedger(pruned, to: fallbackDefaults)
    }

    /// KV の削除の記録をこの端末の記録に統合し、KV と異なれば書き戻す（記録が空で KV にもないときは書かない）。
    /// KV の記録がデコードできないとき（将来の形式など）は上書きしない。
    private func writeDeletionLedgerToKV() {
        let kvLedger: FavoriteDeletionLedger
        switch Self.readLedger(kvStore) {
        case .undecodable:
            iCloudLogger.warning("iCloud deletion ledger is unreadable; skipping iCloud write to preserve it.")
            return
        case .missing:
            kvLedger = FavoriteDeletionLedger()
        case .decoded(let decoded):
            kvLedger = decoded
            updateDeletionLedger(deletionLedger.merging(decoded))
        }
        guard deletionLedger != kvLedger else { return }
        do {
            let data = try JSONEncoder().encode(deletionLedger)
            kvStore.set(data, forKey: Self.deletionLedgerKey)
            kvStore.synchronize()
            iCloudLogger.notice(
                "event=writeDeletionLedger deleted=\(self.deletionLedger.deletedAt.count, privacy: .public) revived=\(self.deletionLedger.revivedAt.count, privacy: .public)"
            )
        } catch {
            iCloudLogger.error("Failed to encode deletion ledger: \(error)")
        }
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
        admitToTombstoneBaseline(Set(added.map(\.id)))
    }

    /// 画面に届いた地点のうち、まだ一覧に残っているものだけを削除の記録の基準に加える。
    private func admitToTombstoneBaseline(_ ids: Set<UUID>) {
        let currentIDs = Set(locations.map(\.id))
        tombstoneBaselineIDs.formUnion(ids.intersection(currentIDs))
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

    private static func readLedger(_ kvStore: any UbiquitousKeyValueStoring) -> LedgerReadResult {
        guard let data = kvStore.data(forKey: deletionLedgerKey) else { return .missing }
        do {
            return .decoded(try JSONDecoder().decode(FavoriteDeletionLedger.self, from: data))
        } catch {
            iCloudLogger.error("Failed to decode deletion ledger from iCloud KVStore: \(error)")
            return .undecodable
        }
    }

    private static func loadPendingAddIDs(_ defaults: UserDefaults) -> Set<UUID> {
        Set((defaults.stringArray(forKey: pendingAddIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func loadLocalDeletionLedger(_ defaults: UserDefaults) -> FavoriteDeletionLedger {
        guard let data = defaults.data(forKey: localDeletionLedgerKey) else { return FavoriteDeletionLedger() }
        do {
            return try JSONDecoder().decode(FavoriteDeletionLedger.self, from: data)
        } catch {
            iCloudLogger.error("Failed to decode local deletion ledger: \(error)")
            return FavoriteDeletionLedger()
        }
    }

    private static func storeLocalDeletionLedger(_ ledger: FavoriteDeletionLedger, to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(ledger), forKey: localDeletionLedgerKey)
        } catch {
            iCloudLogger.error("Failed to encode local deletion ledger: \(error)")
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
