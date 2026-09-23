import Foundation

/// ユーザーが保存した観測地の永続化モデル。
/// - Note: 緯度経度は WGS84、タイムゾーンは IANA 識別子で保持する。
struct FavoriteLocation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// 観測地の緯度（度）。
    var latitude: Double
    /// 観測地の経度（度）。
    var longitude: Double
    /// 観測地の IANA タイムゾーン識別子。
    var timeZoneIdentifier: String
    /// この観測地を登録した日時。
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
    }
}

// MARK: - 同一地点の判定

extension FavoriteLocation {
    /// 同一地点とみなす緯度・経度の差（度）。約111m 以内の別の地点も同一として扱う。
    static let sameSpotTolerance = 0.001

    /// 同じ地点かどうかを返す。ID の一致を優先し、ID が異なる場合は座標の近さで判定する。
    /// - Note: 座標による判定は推移的ではない（A〜B、B〜C が同一でも A〜C は別になりうる）。
    func isSameSpot(as other: FavoriteLocation) -> Bool {
        id == other.id || isNear(latitude: other.latitude, longitude: other.longitude)
    }

    /// 緯度・経度の差がどちらも `sameSpotTolerance` 未満かどうかを返す。
    func isNear(latitude: Double, longitude: Double) -> Bool {
        abs(self.latitude - latitude) < Self.sameSpotTolerance
            && abs(self.longitude - longitude) < Self.sameSpotTolerance
    }
}

extension Array where Element == FavoriteLocation {
    /// `other` のいずれかと同一地点である要素を取り除いた一覧を返す。
    func subtracting(_ other: [FavoriteLocation]) -> [FavoriteLocation] {
        filter { element in !other.contains { element.isSameSpot(as: $0) } }
    }

    /// `other` の要素を先頭から順に、その時点の結果のいずれとも同一でなければ末尾に追加した一覧を返す。
    /// 重複したときは常に左辺（self 側）の要素（名前、id、createdAt）を残す。
    func unionPreservingOrder(_ other: [FavoriteLocation]) -> [FavoriteLocation] {
        var result = self
        for element in other where !result.contains(where: { $0.isSameSpot(as: element) }) {
            result.append(element)
        }
        return result
    }
}
