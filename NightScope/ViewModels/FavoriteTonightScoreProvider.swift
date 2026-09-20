import Foundation
import Combine

/// サイドバーのお気に入り行に表示する「今夜の星空指数」1 件分の表示データ。
struct FavoriteTonightScore: Equatable, Sendable {
    let score: Int
    let tier: StarGazingIndex.Tier
    let bortleClass: Double?
    let computedAt: Date
}

/// お気に入り地点ごとの「今夜の星空指数」をまとめて計算し、キャッシュして公開する。
///
/// `WeatherKitService.fetchWeatherSnapshot` はキャッシュを書かないため、
/// お気に入り 1 件につき WeatherKit 呼び出しが 1 回発生する。
/// そのため TTL（`cacheLifetime`）と件数上限（`maxFavorites`）で呼び出し回数を抑える。
@MainActor
final class FavoriteTonightScoreProvider: ObservableObject {
    /// 計算結果を再利用する有効期間（秒）。
    static let cacheLifetime: TimeInterval = 3600
    /// 1 回の更新で計算する最大地点数。
    static let maxFavorites = 6

    @Published private(set) var scoresByFavoriteID: [UUID: FavoriteTonightScore] = [:]
    @Published private(set) var isRefreshing = false

    private let weatherService: any WeatherProviding
    private let lightPollutionService: any LightPollutionProviding
    private let calculationService: any NightCalculating
    private let referenceDateProvider: () -> Date
    /// 更新要求が重なった際に古い結果で上書きしないための世代カウンタ。
    private var refreshGeneration = 0

    init(
        weatherService: any WeatherProviding,
        lightPollutionService: any LightPollutionProviding,
        calculationService: any NightCalculating,
        referenceDateProvider: @escaping () -> Date = Date.init
    ) {
        self.weatherService = weatherService
        self.lightPollutionService = lightPollutionService
        self.calculationService = calculationService
        self.referenceDateProvider = referenceDateProvider
    }

    /// 指定地点の最新スコアを返す。未計算なら nil。
    func score(for favoriteID: UUID) -> FavoriteTonightScore? {
        scoresByFavoriteID[favoriteID]
    }

    /// キャッシュが古い（または未取得の）お気に入りだけを対象に今夜の指数を計算する。
    /// - Parameter force: true なら TTL を無視して対象全件を再計算する。
    func refreshIfNeeded(favorites: [FavoriteLocation], force: Bool = false) async {
        let referenceDate = referenceDateProvider()
        let candidates = Array(favorites.prefix(Self.maxFavorites))
        let targets = candidates.filter { favorite in
            guard !force, let cached = scoresByFavoriteID[favorite.id] else { return true }
            return referenceDate.timeIntervalSince(cached.computedAt) >= Self.cacheLifetime
        }
        guard !targets.isEmpty else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            // 後発の更新が走っている場合は、そちらに isRefreshing の解除を任せる。
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        let matrix = await ComparisonController.computeMatrix(
            referenceDate: referenceDate,
            locations: targets,
            dayCount: 1,
            weatherService: weatherService,
            lightPollutionService: lightPollutionService,
            calculationService: calculationService
        )

        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard let tonight = matrix.dates.first else { return }

        // 取得に失敗した地点は既存値を残し、成功した地点だけを差し替える。
        var updated = scoresByFavoriteID
        for target in targets {
            let cellID = ComparisonCell.makeID(locationID: target.id, date: tonight)
            guard let index = matrix.cellsByID[cellID]?.index else { continue }
            updated[target.id] = FavoriteTonightScore(
                score: index.score,
                tier: index.tier,
                bortleClass: matrix.cellsByID[cellID]?.bortleClass,
                computedAt: referenceDate
            )
        }
        scoresByFavoriteID = updated
    }
}
