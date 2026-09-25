import Foundation

/// お気に入りのストアと、iCloud 同期を担う FavoriteSyncReconciler を組み立てる。
@MainActor
enum FavoritesComposition {
    /// 同じ寿命で使うストアと reconciler の組。
    struct Components {
        let store: any FavoriteLocationStoring
        let reconciler: FavoriteSyncReconciler
    }

    static func make(
        defaults: UserDefaults,
        kvStore: any UbiquitousKeyValueStoring,
        center: NotificationCenter
    ) -> Components {
        let store = makeFavoriteStore(defaults: defaults, kvStore: kvStore, center: center)
        let reconciler = FavoriteSyncReconciler(
            activeStore: store,
            localDefaults: defaults,
            kvStore: kvStore,
            toggleProvider: { defaults.bool(forKey: AppSettingsKeys.iCloudSyncEnabled) }
        )
        return Components(store: store, reconciler: reconciler)
    }

    /// iCloud 同期設定に応じて適切な FavoriteLocationStore を生成する。
    /// 自動移行はしない（KV を正とし、ローカルとの差分は FavoriteSyncReconciler が扱う）。
    private static func makeFavoriteStore(
        defaults: UserDefaults,
        kvStore: any UbiquitousKeyValueStoring,
        center: NotificationCenter
    ) -> any FavoriteLocationStoring {
        guard defaults.bool(forKey: AppSettingsKeys.iCloudSyncEnabled) else {
            return FavoriteLocationStore(userDefaults: defaults)
        }
        return iCloudFavoriteLocationStore(kvStore: kvStore, fallbackDefaults: defaults, notificationCenter: center)
    }
}
