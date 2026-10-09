import Foundation
import Combine

/// サイドバーのお気に入り行に表示する「今夜の星空指数」1 件分の表示データ。
struct FavoriteTonightScore: Equatable, Sendable {
    let score: Int
    let tier: StarGazingIndex.Tier
    let bortleClass: Double?
    let computedAt: Date
    /// このスコアが対象とする観測夜（列のタイムゾーンの暦日 0 時）。夜が切り替わったらキャッシュを無効にする。
    let observationDate: Date
}

/// お気に入り地点ごとの「今夜の星空指数」をまとめて計算し、キャッシュして公開する。
///
/// `WeatherKitService.fetchWeatherSnapshot` はキャッシュを書かないため、
/// お気に入り 1 件につき WeatherKit 呼び出しが 1 回発生する。
/// そのため TTL（`cacheLifetime`）で呼び出し回数を抑える。
@MainActor
final class FavoriteTonightScoreProvider: ObservableObject {
    /// 計算結果を再利用する有効期間（秒）。
    static let cacheLifetime: TimeInterval = 3600
    /// 取得に失敗した地点を再試行するまでの待ち時間（秒）。`force` のときは無視する。
    static let failureRetryInterval: TimeInterval = 300

    @Published private(set) var scoresByFavoriteID: [UUID: FavoriteTonightScore] = [:]
    @Published private(set) var isRefreshing = false

    private let weatherService: any WeatherProviding
    private let lightPollutionService: any LightPollutionProviding
    private let calculationService: any NightCalculating
    private let referenceDateProvider: () -> Date
    /// 更新要求が重なった際に古い結果で上書きしないための世代カウンタ。
    private var refreshGeneration = 0
    /// 地点ごとの直近の取得失敗時刻。バックオフ判定に使う。
    private var lastFailureByFavoriteID: [UUID: Date] = [:]

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

        // 削除済みのお気に入りのキャッシュを刈り込む。
        let favoriteIDs = Set(favorites.map(\.id))
        if scoresByFavoriteID.keys.contains(where: { !favoriteIDs.contains($0) }) {
            scoresByFavoriteID = scoresByFavoriteID.filter { favoriteIDs.contains($0.key) }
        }
        lastFailureByFavoriteID = lastFailureByFavoriteID.filter { favoriteIDs.contains($0.key) }

        let targets = favorites.filter { favorite in
            if !force, let failedAt = lastFailureByFavoriteID[favorite.id],
               referenceDate.timeIntervalSince(failedAt) < Self.failureRetryInterval {
                return false
            }
            guard !force, let cached = scoresByFavoriteID[favorite.id] else { return true }
            return referenceDate.timeIntervalSince(cached.computedAt) >= Self.cacheLifetime
                || cached.observationDate != observationDate(for: favorite, referenceDate: referenceDate)
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

        // 「今夜」（観測日）は地点ごとに異なる（時差や深夜〜明け方の前夜）ため、地点ごとに 1 列の行列を作る。
        // まとめて計算すると列が最も早い観測日にそろい、他の地点で終わった夜の指数を出してしまう。
        // 取得に失敗した地点は既存値を残し、成功した地点だけを差し替える。
        // 地点ごとに、更新が世代交代していない間は即座に反映する（途中でやめても完了分は失われない）。
        for target in targets {
            let matrix = await ComparisonController.computeMatrix(
                referenceDate: referenceDate,
                locations: [target],
                dayCount: 1,
                weatherService: weatherService,
                lightPollutionService: lightPollutionService,
                calculationService: calculationService
            )
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            // 天気の取得に失敗した結果は正規の値として保存しない。
            // 既存値は同じ観測夜のものだけ残し、過去の夜の値は「今夜」として出さないよう取り除く。
            guard !matrix.weatherFailedLocationIDs.contains(target.id),
                  let tonight = matrix.dates.first,
                  let index = matrix.cellsByID[ComparisonCell.makeID(locationID: target.id, date: tonight)]?.index
            else {
                lastFailureByFavoriteID[target.id] = referenceDate
                if let cached = scoresByFavoriteID[target.id],
                   cached.observationDate != observationDate(for: target, referenceDate: referenceDate) {
                    scoresByFavoriteID[target.id] = nil
                }
                continue
            }
            let cellID = ComparisonCell.makeID(locationID: target.id, date: tonight)
            lastFailureByFavoriteID[target.id] = nil
            scoresByFavoriteID[target.id] = FavoriteTonightScore(
                score: index.score,
                tier: index.tier,
                bortleClass: matrix.cellsByID[cellID]?.bortleClass,
                computedAt: referenceDate,
                observationDate: tonight
            )
        }
    }

    /// その地点の「今夜」にあたる観測夜（列のタイムゾーンの暦日）。
    private func observationDate(for favorite: FavoriteLocation, referenceDate: Date) -> Date {
        ComparisonController.makeDates(
            referenceDate: referenceDate,
            dayCount: 1,
            timeZone: .current,
            locations: [favorite]
        ).first ?? referenceDate
    }
}
