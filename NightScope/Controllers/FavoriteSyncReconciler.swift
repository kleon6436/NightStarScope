import Foundation
import Combine

/// iCloud とこの端末のお気に入りの差分を求め、ユーザーが選んだ地点だけを取り込む。
/// 自動では統合しない。書き込みはすべて稼働中のストアの `save` を通し、UserDefaults のローカルキーには直接書かない。
@MainActor
final class FavoriteSyncReconciler: ObservableObject {
    /// 稼働中のストアの同期モード。
    enum Mode: Equatable {
        case icloud
        case local
    }

    /// バナーを「あとで」で閉じたときの `localOnly` の ID 集合を保存するキー（端末ローカル）。
    static let dismissedLocalOnlyIDsKey = "favorites.sync.dismissedLocalOnlyIDs"

    /// 稼働中のストアの型から決めたモード（トグルの値ではない）。
    let activeMode: Mode
    /// iCloud モードで、この端末にのみある地点（`favorites.locations − activeStore`）。
    @Published private(set) var localOnly: [FavoriteLocation] = []
    /// local モードで、iCloud にのみある地点（`KV − activeStore`）。`refresh()` で計算する。
    @Published private(set) var cloudOnly: [FavoriteLocation] = []
    @Published private var dismissedLocalOnlyIDs: Set<UUID>

    private let activeStore: any FavoriteLocationStoring
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
        self.activeMode = activeStore is iCloudFavoriteLocationStore ? .icloud : .local
        let dismissed = localDefaults.stringArray(forKey: Self.dismissedLocalOnlyIDsKey) ?? []
        self.dismissedLocalOnlyIDs = Set(dismissed.compactMap(UUID.init(uuidString:)))
        // isPendingRestart と isLocalOnlyBannerVisible はトグルを読む計算プロパティなので、トグルが変わったら画面に知らせる。
        // UserDefaults の変更通知は書き込んだスレッドで届くため、MainActor に隔離された map の前でメインへ移す。
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: localDefaults)
            .receive(on: DispatchQueue.main)
            .map { _ in toggleProvider() }
            .prepend(toggleProvider())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        guard activeMode == .icloud else { return }
        // 退避と削除の反映は locations を更新する前にローカルへ書き終えているので、この購読だけで拾える。
        // @Published は値の確定前に流れるため、loadAll() ではなく流れてきた値を使う。
        activeStore.locationsPublisher
            .sink { [weak self] active in
                self?.recomputeLocalOnly(active: active)
            }
            .store(in: &cancellables)
    }

    /// トグルと稼働中のモードが食い違っている（再起動後に反映される）。この間はすべての操作を無効にする。
    var isPendingRestart: Bool {
        toggleProvider() != (activeMode == .icloud)
    }

    /// サイドバーの件数バナーを出すかどうか。「あとで」で閉じた時点から `localOnly` の ID 集合が変わっていれば再表示する。
    var isLocalOnlyBannerVisible: Bool {
        activeMode == .icloud
            && !localOnly.isEmpty
            && !isPendingRestart
            && Set(localOnly.map(\.id)) != dismissedLocalOnlyIDs
    }

    /// 差分を計算し直す。local モードでは画面の表示時に呼ぶ。
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
        return saveUnion(with: selected)
    }

    /// 選んだ地点をこの端末に取り込み、追加した件数を返す。local モードのときだけ使える。
    @discardableResult
    func importToLocal(_ selected: [FavoriteLocation]) -> Int {
        guard activeMode == .local, !isPendingRestart else { return 0 }
        let added = saveUnion(with: selected)
        cloudOnly = cloudOnly.subtracting(activeStore.loadAll())
        return added
    }

    /// その時点の `localOnly` の ID 集合を記憶し、集合が変わるまでバナーを出さない。
    func dismissLocalOnlyBanner() {
        dismissedLocalOnlyIDs = Set(localOnly.map(\.id))
        localDefaults.set(dismissedLocalOnlyIDs.map(\.uuidString), forKey: Self.dismissedLocalOnlyIDsKey)
    }

    // MARK: - Private

    private func recomputeLocalOnly(active: [FavoriteLocation]) {
        localOnly = FavoriteLocationStore.loadFavorites(userDefaults: localDefaults).subtracting(active)
    }

    /// 稼働中のストアの一覧を左辺にした和集合を保存する。重複したときはストア側の名前が残る。
    private func saveUnion(with selected: [FavoriteLocation]) -> Int {
        let current = activeStore.loadAll()
        let merged = current.unionPreservingOrder(selected)
        let added = merged.count - current.count
        guard added > 0 else { return 0 }
        activeStore.save(merged)
        return added
    }
}
