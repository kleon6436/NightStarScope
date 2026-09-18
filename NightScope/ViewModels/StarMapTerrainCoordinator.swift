import Foundation

/// 地形プロファイル取得の差し替え可能な依存関係。
struct StarMapTerrainDependency: Sendable {
    let fetchProfile: @Sendable (_ latitude: Double, _ longitude: Double) async -> TerrainProfile?

    static let live = StarMapTerrainDependency(
        fetchProfile: { latitude, longitude in
            await TerrainService.shared.fetchProfile(latitude: latitude, longitude: longitude)
        }
    )
}

/// 地形取得の進捗状態。
enum StarMapTerrainFetchState: Equatable {
    case idle
    case loading
    case available
    case unavailable

    var statusText: String {
        switch self {
        case .idle:
            L10n.tr("地形: 待機中")
        case .loading:
            L10n.tr("地形: 読込中")
        case .available:
            L10n.tr("地形: 有効")
        case .unavailable:
            L10n.tr("地形: 未取得")
        }
    }

    var systemImageName: String {
        switch self {
        case .idle, .loading:
            "hourglass"
        case .available:
            "mountain.2"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }
}

/// 地形フェッチ取得の進捗状態。
@MainActor
final class StarMapTerrainCoordinator {
    private let dependency: StarMapTerrainDependency
    private var lastKey: String = ""
    private var fetchTask: Task<Void, Never>?

    init(dependency: StarMapTerrainDependency) {
        self.dependency = dependency
    }

    deinit {
        fetchTask?.cancel()
    }

    /// キャッシュキーが前回と異なる場合のみ地形を取得し、状態変化を onStateChange で通知する。
    func scheduleFetchIfNeeded(
        latitude: Double,
        longitude: Double,
        cacheKey: String,
        onStateChange: @escaping (TerrainProfile?, StarMapTerrainFetchState) -> Void
    ) {
        guard cacheKey != lastKey else { return }
        lastKey = cacheKey
        onStateChange(nil, .loading)

        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let profile = await dependency.fetchProfile(latitude, longitude)
            guard !Task.isCancelled else { return }
            guard cacheKey == self.lastKey else { return }
            onStateChange(profile, profile == nil ? .unavailable : .available)
        }
    }

    func cancel() {
        fetchTask?.cancel()
    }
}
