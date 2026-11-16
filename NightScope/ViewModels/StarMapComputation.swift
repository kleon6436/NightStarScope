import SwiftUI

/// 星図描画に必要な天体位置をまとめて計算するユーティリティ。
enum StarMapComputation {
    /// 1 回の描画に必要な計算結果のスナップショット。
    struct Snapshot: Sendable {
        let starField: StarField
        let sunAltitude: Double
        let moonAltitude: Double
        let moonAzimuth: Double
        let moonPhase: Double
        let galacticCenterAltitude: Double
        let galacticCenterAzimuth: Double
        let constellationLines: [ConstellationLineSegment]
        let constellationLabels: [ConstellationLabelAltAz]
        let planetPositions: [PlanetPosition]
        let meteorShowerRadiants: [(shower: MeteorShower, altitude: Double, azimuth: Double)]
        let milkyWayBandPoints: [MilkyWayBandPoint]
        /// 月の輝面の向き（天頂方向 0°、観測者から見て左回り, 度）。
        /// `MilkyWayCalculator.moonBrightLimbZenithAngle` の値。nil の場合は描画側で従来の左右表示にする。
        var moonBrightLimbZenithAngle: Double? = nil
    }

    /// この高度（度）以下の恒星は描画・選択の対象にしない。
    static let starHorizonCutoffAltitude: Double = -3
    /// `starHorizonCutoffAltitude` の正弦。地平座標の天頂成分と直接比べる。
    static let sinStarHorizonCutoff: Double = sin(starHorizonCutoffAltitude * .pi / 180)

    /// 恒星カタログの時刻に依存しない幾何情報（構造体の配列ではなく成分ごとの配列）。
    /// 赤道座標の単位ベクトルはカタログ読込後に 1 回だけ作り、時刻が変わっても使い回す。
    struct CatalogGeometry: Sendable {
        let x: [Double]
        let y: [Double]
        let z: [Double]
        let magnitudes: [Double]
        let colorBuckets: [Int]
        let colors: [Color]
    }

    static let catalogGeometry: CatalogGeometry = {
        let catalog = StarCatalog.stars
        var x = [Double](), y = [Double](), z = [Double]()
        x.reserveCapacity(catalog.count)
        y.reserveCapacity(catalog.count)
        z.reserveCapacity(catalog.count)
        for star in catalog {
            let vector = MilkyWayCalculator.SkyRotation.unitVector(ra: star.ra, dec: star.dec)
            x.append(vector.x)
            y.append(vector.y)
            z.append(vector.z)
        }
        return CatalogGeometry(
            x: x,
            y: y,
            z: z,
            magnitudes: catalog.map(\.magnitude),
            colorBuckets: catalog.map { StarMapStarStyle.colorBucket(forBV: $0.colorIndex) },
            colors: catalog.map { starColorForBV($0.colorIndex) }
        )
    }()

    /// 表示密度ごとのカタログ番号（カタログ順）。明るい星は 1 個ずつ、暗い星はまとめて描くため分けて持つ。
    private struct DensityIndices: Sendable {
        let bright: [Int]
        let faint: [Int]
    }

    private static let indicesByDensity: [StarDisplayDensity: DensityIndices] = {
        let magnitudes = catalogGeometry.magnitudes
        var result: [StarDisplayDensity: DensityIndices] = [:]
        for density in StarDisplayDensity.allCases {
            let limit = density.maxMagnitude
            var bright: [Int] = []
            var faint: [Int] = []
            for index in magnitudes.indices where magnitudes[index] <= limit {
                if magnitudes[index] < StarMapStarStyle.glowMagnitudeLimit {
                    bright.append(index)
                } else {
                    faint.append(index)
                }
            }
            result[density] = DensityIndices(bright: bright, faint: faint)
        }
        return result
    }()

    /// 星図に描く恒星の集合。表示密度で絞ったカタログ番号と、その時刻の赤道→地平回転だけを持つ。
    /// 地平線のカットや高度・画面位置は描画時に回転から求める（時刻が変わっても恒星ごとの計算をしない）。
    struct StarField: Sendable {
        let rotation: MilkyWayCalculator.SkyRotation
        /// 等級が `StarMapStarStyle.glowMagnitudeLimit` 未満の星（カタログ順）。
        let brightCatalogIndices: [Int]
        /// それ以外の星（カタログ順）。
        let faintCatalogIndices: [Int]

        static let empty = StarField(
            rotation: MilkyWayCalculator.SkyRotation(latitude: 0, localSiderealTime: 0),
            brightCatalogIndices: [],
            faintCatalogIndices: []
        )

        /// 表示密度を満たす星の数（地平線下を含む）。
        var count: Int { brightCatalogIndices.count + faintCatalogIndices.count }
        var isEmpty: Bool { count == 0 }

        /// 地平線カット（高度 > -3°）と視野内判定を通る星を、高度の正弦と画面位置とともにカタログ順で渡す。
        /// 恒星 1 個あたり内積 4 回と除算だけ（三角関数なし）。毎フレーム全星を回るため、
        /// 最適化なしのビルドでも遅くならないよう回転・投影の成分をローカルへ展開している。
        func forEachProjectedStar(
            in indices: [Int],
            projector: GnomonicProjectionMath.EquatorialProjector,
            _ body: (_ catalogIndex: Int, _ sinAltitude: Double, _ point: CGPoint) -> Void
        ) {
            let geometry = StarMapComputation.catalogGeometry
            let sinCutoff = StarMapComputation.sinStarHorizonCutoff
            let (ux, uy, uz) = (rotation.upX, rotation.upY, rotation.upZ)
            let (fx, fy, fz) = (projector.forward.x, projector.forward.y, projector.forward.z)
            let (rx, ry, rz) = (projector.right.x, projector.right.y, projector.right.z)
            let (vx, vy, vz) = (projector.up.x, projector.up.y, projector.up.z)
            let (cx, cy, scale) = (projector.cx, projector.cy, projector.scale)
            geometry.x.withUnsafeBufferPointer { xs in
                geometry.y.withUnsafeBufferPointer { ys in
                    geometry.z.withUnsafeBufferPointer { zs in
                        for index in indices {
                            let x = xs[index], y = ys[index], z = zs[index]
                            let sinAltitude = ux * x + uy * y + uz * z
                            guard sinAltitude > sinCutoff else { continue }
                            // `GnomonicProjectionMath.projectPoint(horizontal:)` と同じ式。
                            let dot = fx * x + fy * y + fz * z
                            guard dot > 0.1 else { continue }
                            let px = (rx * x + ry * y + rz * z) / dot * scale
                            let py = (vx * x + vy * y + vz * z) / dot * scale
                            body(index, sinAltitude, CGPoint(x: cx + px, y: cy - py))
                        }
                    }
                }
            }
        }

        /// 地平線カット（高度 > -3°）を通る星の位置。通らなければ nil。
        func starPosition(catalogIndex index: Int) -> StarPosition? {
            let geometry = StarMapComputation.catalogGeometry
            let x = geometry.x[index], y = geometry.y[index], z = geometry.z[index]
            guard rotation.sinAltitude(x: x, y: y, z: z) > StarMapComputation.sinStarHorizonCutoff else {
                return nil
            }
            let (altitude, azimuth) = rotation.altAz(x: x, y: y, z: z)
            // 正弦での判定と asin 後の度数での判定が丸めで食い違う境界の星は、従来の度数判定に合わせる。
            guard altitude > StarMapComputation.starHorizonCutoffAltitude else { return nil }
            return StarPosition(
                catalogIndex: index,
                star: StarCatalog.stars[index],
                altitude: altitude,
                azimuth: azimuth,
                precomputedColor: geometry.colors[index],
                colorBucket: geometry.colorBuckets[index]
            )
        }

        /// 等級 `maxMagnitude` 以下で地平線カットを通る星の位置（カタログ順）。タップ判定用。
        func starPositions(maxMagnitude: Double) -> [StarPosition] {
            let magnitudes = StarMapComputation.catalogGeometry.magnitudes
            var indices = brightCatalogIndices.filter { magnitudes[$0] <= maxMagnitude }
            indices += faintCatalogIndices.filter { magnitudes[$0] <= maxMagnitude }
            indices.sort()
            return indices.compactMap { starPosition(catalogIndex: $0) }
        }
    }

    /// 星座線の端点の赤道座標単位ベクトル（`ConstellationData.constellations` の線分順）。
    private static let constellationSegmentVectors: [(
        start: (x: Double, y: Double, z: Double),
        end: (x: Double, y: Double, z: Double)
    )] = ConstellationData.constellations.flatMap { entry in
        entry.segments.map { segment in
            (
                start: MilkyWayCalculator.SkyRotation.unitVector(ra: segment.ra1, dec: segment.dec1),
                end: MilkyWayCalculator.SkyRotation.unitVector(ra: segment.ra2, dec: segment.dec2)
            )
        }
    }

    /// 両端がこの高度（度）以下の星座線は描かない。
    private static let sinConstellationLineCutoff = sin(-15.0 * .pi / 180)
    /// 星座線の端点はこの高度（度）未満なら持ち上げて描く。
    private static let constellationLineMinimumAltitude = -5.0 * .pi / 180

    /// 高度が `constellationLineMinimumAltitude` 未満の方向を、方位を保ったままその高度へ持ち上げる。
    static func clampedToConstellationLineMinimumAltitude(
        _ vector: (x: Double, y: Double, z: Double)
    ) -> (x: Double, y: Double, z: Double) {
        let sinMinimum = sin(constellationLineMinimumAltitude)
        guard vector.z < sinMinimum else { return vector }
        let cosMinimum = cos(constellationLineMinimumAltitude)
        let horizontalLength = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        // 天底では方位が定まらない。altAzFast と同じく方位 0（北）とみなす。
        guard horizontalLength > 1e-10 else { return (0, cosMinimum, sinMinimum) }
        let scale = cosMinimum / horizontalLength
        return (vector.x * scale, vector.y * scale, sinMinimum)
    }

    static func compute(
        latitude: Double,
        longitude: Double,
        julianDate: Double,
        localSiderealTime: Double,
        activeMeteorShowers: [MeteorShower],
        starDisplayDensity: StarDisplayDensity
    ) -> Snapshot {
        let signposter = PerformanceSignposts.signposter
        let signpostState = signposter.beginInterval("StarMapCompute", id: signposter.makeSignpostID())
        defer { signposter.endInterval("StarMapCompute", signpostState) }
        let latRad = latitude * .pi / 180.0
        let observer = MilkyWayCalculator.HorizontalObserver(
            cosLat: cos(latRad),
            sinLat: sin(latRad),
            lst: localSiderealTime
        )
        let rotation = MilkyWayCalculator.SkyRotation(latitude: latitude, localSiderealTime: localSiderealTime)

        let densityIndices = indicesByDensity[starDisplayDensity] ?? DensityIndices(bright: [], faint: [])
        let starField = StarField(
            rotation: rotation,
            brightCatalogIndices: densityIndices.bright,
            faintCatalogIndices: densityIndices.faint
        )

        let sun = MilkyWayCalculator.sunRaDec(jd: julianDate)
        let (sunAltitude, _) = observer.altAz(ra: sun.ra, dec: sun.dec)

        // 視差補正済みの地平座標を使い、タイムラインやイベント計算と同じ月高度にそろえる
        let moon = MilkyWayCalculator.moonHorizontal(jd: julianDate, observer: observer)
        let moonAltitude = moon.alt
        let moonAzimuth = moon.az

        let (galacticCenterAltitude, galacticCenterAzimuth) = observer.altAz(
            ra: MilkyWayCalculator.gcRA,
            dec: MilkyWayCalculator.gcDec
        )

        var constellationLines: [ConstellationLineSegment] = []
        constellationLines.reserveCapacity(constellationSegmentVectors.count)
        for segment in constellationSegmentVectors {
            let start = rotation.horizontal(x: segment.start.x, y: segment.start.y, z: segment.start.z)
            let end = rotation.horizontal(x: segment.end.x, y: segment.end.y, z: segment.end.z)
            guard start.z > sinConstellationLineCutoff || end.z > sinConstellationLineCutoff else { continue }
            constellationLines.append(
                ConstellationLineSegment(
                    start: clampedToConstellationLineMinimumAltitude(start),
                    end: clampedToConstellationLineMinimumAltitude(end)
                )
            )
        }

        let constellationNames = ConstellationData.localizedNames()
        let constellationLabels: [ConstellationLabelAltAz] = zip(
            ConstellationData.constellations,
            constellationNames
        ).compactMap { entry, name in
            let (altitude, azimuth) = observer.altAz(ra: entry.centerRA, dec: entry.centerDec)
            guard altitude > -5 else { return nil }
            return ConstellationLabelAltAz(alt: altitude, az: azimuth, name: name)
        }

        let meteorRadiants = activeMeteorShowers.map { shower in
            let (altitude, azimuth) = observer.altAz(ra: shower.radiantRA, dec: shower.radiantDec)
            return (shower: shower, altitude: altitude, azimuth: azimuth)
        }

        return Snapshot(
            starField: starField,
            sunAltitude: sunAltitude,
            moonAltitude: moonAltitude,
            moonAzimuth: moonAzimuth,
            moonPhase: moon.phase,
            galacticCenterAltitude: galacticCenterAltitude,
            galacticCenterAzimuth: galacticCenterAzimuth,
            constellationLines: constellationLines,
            constellationLabels: constellationLabels,
            planetPositions: MilkyWayCalculator.planetPositions(
                jd: julianDate,
                latitude: latitude,
                lst: localSiderealTime
            ),
            meteorShowerRadiants: meteorRadiants,
            milkyWayBandPoints: computeMilkyWayBandPoints(observer: observer),
            moonBrightLimbZenithAngle: MilkyWayCalculator.moonBrightLimbZenithAngle(
                jd: julianDate,
                latitude: latitude,
                localSiderealTime: localSiderealTime
            )
        )
    }

    /// 天の川バンドのサンプリング間隔（銀経, 度）
    static let milkyWayBandLongitudeStep: Double = 5

    /// 天の川バンドで隣り合う（銀経が 1 ステップ差の）点のインデックス組を返す。
    /// 銀経 355° → 0° の区間も閉じ、地平線下で間引かれた区間はつながない。
    static func milkyWayBandSegmentIndexPairs(
        for points: [MilkyWayBandPoint]
    ) -> [(start: Int, end: Int)] {
        guard points.count > 1 else { return [] }
        let step = milkyWayBandLongitudeStep
        var pairs: [(start: Int, end: Int)] = []
        pairs.reserveCapacity(points.count)
        for index in points.indices {
            let nextIndex = (index + 1) % points.count
            guard nextIndex != index else { continue }
            var longitudeDelta = (points[nextIndex].li - points[index].li)
                .truncatingRemainder(dividingBy: 360)
            if longitudeDelta < 0 { longitudeDelta += 360 }
            guard abs(longitudeDelta - step) < 1e-6 else { continue }
            pairs.append((start: index, end: nextIndex))
        }
        return pairs
    }

    private static func computeMilkyWayBandPoints(
        observer: MilkyWayCalculator.HorizontalObserver
    ) -> [MilkyWayBandPoint] {
        var result = [MilkyWayBandPoint]()
        let step = milkyWayBandLongitudeStep

        for longitude in stride(from: 0.0, to: 360.0, by: step) {
            // 銀河面が十分に見える区間だけを点列として残す。
            let equatorialCenter = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: 0)
            let (altitudeCenter, azimuthCenter) = observer.altAz(ra: equatorialCenter.ra, dec: equatorialCenter.dec)
            guard altitudeCenter > -5 else { continue }

            let bandWidth: Double = longitude > 270 || longitude < 90 ? 12 : 8
            let upper = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: bandWidth)
            let lower = MilkyWayCalculator.galacticToEquatorial(l: longitude, b: -bandWidth)
            let (upperAltitude, _) = observer.altAz(ra: upper.ra, dec: upper.dec)
            let (lowerAltitude, _) = observer.altAz(ra: lower.ra, dec: lower.dec)

            result.append(
                MilkyWayBandPoint(
                    az: azimuthCenter,
                    alt: altitudeCenter,
                    halfH: max(3.0, abs(upperAltitude - lowerAltitude) / 2),
                    li: longitude
                )
            )
        }

        return result
    }
}
