import SwiftUI
import Foundation

// MARK: - Star Map Presentation

enum StarMapLayout {
    static let minFOV: Double = 30
    static let maxFOV: Double = 150
    static let defaultFOV: Double = 60
    static let resetAltitude: Double = 30
    static let directionStep: Double = 5
    static let zoomStep: Double = 10
    static let timeLabelWidth: CGFloat = 52
    static let sheetMinWidth: CGFloat = 900
    static let sheetMinHeight: CGFloat = 760
    static let canvasMinWidth: CGFloat = 860
    static let canvasMinHeight: CGFloat = 620
    static let cardinalLabelBottomInset: CGFloat = 28
    static let cardinalLabelSidePadding: CGFloat = 12
    static let cardinalLabelHorizontalPadding: CGFloat = 8
    static let cardinalLabelVerticalPadding: CGFloat = 4
    /// 画面外の方位ラベルを端へ寄せる際に、他ラベルと重ならないよう確保する最小間隔。
    static let cardinalLabelMinimumSpacing: Double = 40
    /// カメラ背景に合わせる視野角の下限・上限（手動ズーム用の 30° 下限とは別）。
    static let minCameraFOV: Double = 1
    static let maxCameraFOV: Double = 170
    /// macOS 星空マップ下部バーの操作行の高さ。
    static let macControlRowHeight: CGFloat = 28
    /// macOS 星空マップ下部バーのステータスチップ間隔。
    static let macStatusChipSpacing: CGFloat = 16
    /// Slider のつまみ半径ぶんヒートバーを内側へ寄せる量。
    static let macHeatBarTrackInset: CGFloat = 10

    static func clampedFOV(_ value: Double) -> Double {
        max(minFOV, min(maxFOV, value))
    }

    /// カメラ実画角を投影に使うための視野角。望遠カメラ等の狭い画角もそのまま扱う。
    static func clampedCameraFOV(_ value: Double) -> Double {
        max(minCameraFOV, min(maxCameraFOV, value))
    }
}

enum StarMapPalette {
    static let canvasBackground = Color(red: 0.02, green: 0.04, blue: 0.12)
    static let groundFill = Color(red: 0.06, green: 0.04, blue: 0.02)
    static let meteorAccent = Color(red: 0.4, green: 1.0, blue: 0.7)
    /// 星図の外（通常のウィンドウ背景）に置く文字用。ライトモードでは白地で読めるよう濃くする。
    static let meteorAccentOnSurface = Color.adaptive(light: surfaceAccentLight, dark: meteorAccent)
    /// 地形データ取得済みの表示色。星図の外の文字に使うため、ライトモードでは濃くする。
    static let terrainAvailable = Color.adaptive(
        light: surfaceAccentLight,
        dark: Color(red: 0.4, green: 1.0, blue: 0.7)
    )
    private static let surfaceAccentLight = Color(red: 0.0, green: 0.48, blue: 0.33)

    // MARK: - Dynamic Sky Color

    /// 太陽高度・月光に基づく動的空色を返す
    static func skyColor(sunAltitude: Double, moonAltitude: Double, moonPhase: Double) -> Color {
        let (r, g, b) = skyBaseRGB(sunAltitude: sunAltitude)
        let moonWash = moonBrightness(moonAltitude: moonAltitude, moonPhase: moonPhase)
        return Color(
            red: min(1, r + moonWash * 0.03),
            green: min(1, g + moonWash * 0.04),
            blue: min(1, b + moonWash * 0.08)
        )
    }

    /// 月光による暗い星の減光係数 (1.0 = 影響なし)
    static func moonDimmingFactor(moonBrightness: Double, starMagnitude: Double) -> Double {
        guard moonBrightness > 0, starMagnitude > 3.0 else { return 1.0 }
        let sensitivity = min(1.0, (starMagnitude - 3.0) / 4.0)
        return max(0.2, 1.0 - moonBrightness * sensitivity * 0.6)
    }

    /// 月光の総合的な明るさ (0 = 影響なし, 1 = 最大)
    static func moonBrightness(moonAltitude: Double, moonPhase: Double) -> Double {
        guard moonAltitude > 0 else { return 0 }
        let illumination = (1.0 - cos(moonPhase * 2.0 * .pi)) / 2.0
        return illumination * min(1, moonAltitude / 45)
    }

    /// シンチレーション係数 (1.0 中心の微小変動)
    static func scintillation(
        starRA: Double, magnitude: Double, altitude: Double,
        isDark: Bool, time: Double
    ) -> Double {
        guard isDark, magnitude < 2.0 else { return 1.0 }
        let freq = 2.5 + (starRA.truncatingRemainder(dividingBy: 7)) * 0.4
        let phase = starRA * 137.5
        let altFactor = altitude < 30 ? (1.5 - altitude / 60) : 1.0
        let amplitude = (2.0 - magnitude) / 2.0 * 0.15 * altFactor
        return 1.0 + amplitude * sin(time * freq + phase)
    }

    // MARK: - Private

    private static let skyColorStops: [(alt: Double, r: Double, g: Double, b: Double)] = [
        (alt:  10, r: 0.40, g: 0.60, b: 0.85),
        (alt:   5, r: 0.30, g: 0.40, b: 0.70),
        (alt:   0, r: 0.20, g: 0.15, b: 0.40),
        (alt:  -6, r: 0.08, g: 0.08, b: 0.25),
        (alt: -12, r: 0.04, g: 0.06, b: 0.18),
        (alt: -18, r: 0.02, g: 0.04, b: 0.12),
    ]

    private static func skyBaseRGB(sunAltitude: Double) -> (Double, Double, Double) {
        let stops = skyColorStops
        if sunAltitude >= stops[0].alt {
            return (stops[0].r, stops[0].g, stops[0].b)
        }
        if sunAltitude <= stops[stops.count - 1].alt {
            return (stops[stops.count - 1].r, stops[stops.count - 1].g, stops[stops.count - 1].b)
        }
        for i in 0..<(stops.count - 1) {
            let upper = stops[i]
            let lower = stops[i + 1]
            if sunAltitude <= upper.alt && sunAltitude >= lower.alt {
                let t = (sunAltitude - lower.alt) / (upper.alt - lower.alt)
                return (
                    lower.r + (upper.r - lower.r) * t,
                    lower.g + (upper.g - lower.g) * t,
                    lower.b + (upper.b - lower.b) * t
                )
            }
        }
        return (0.02, 0.04, 0.12)
    }
}

// MARK: - Star Rendering

/// 恒星 1 個の見た目（半径・不透明度）と、暗い星をまとめて塗るためのバケット分けを決める純粋関数群。
/// Canvas の描画ループから毎フレーム呼ばれる。
enum StarMapStarStyle {
    /// この等級より明るい星はグローとシンチレーションを持ち、1 個ずつ描く。
    /// それ以外は円 1 枚だけなので、同じ色・不透明度の星を 1 つの Path にまとめて塗る。
    static let glowMagnitudeLimit = 2.0
    /// この等級より明るい星は外側のグローも描く。
    static let outerGlowMagnitudeLimit = 0.5
    /// この等級より明るい名前付きの星にラベルを付ける。
    static let labelMagnitudeLimit = 1.5
    /// ラベル付きの星を画面外として省く際の余白（ラベル文字列が星の右側へはみ出す分）。
    static let labelCullingMargin = 120.0

    static func radius(magnitude: Double) -> Double {
        max(0.8, 5 - (magnitude + 1.5) * (4 / 4.5))
    }

    /// シンチレーションを除いた本体円の不透明度。
    static func coreOpacity(magnitude: Double, isDark: Bool, altitude: Double, moonBrightness: Double) -> Double {
        let opacity = isDark ? 1.0 : max(0.1, 0.3 - magnitude * 0.05)
        let brightness = magnitude < 0 ? 1.0 : max(0.6, 1.0 - magnitude * 0.12)
        // 大気消光: 仰角 15° 以下で徐々に減光
        let extinction = altitude < 15 ? max(0, altitude / 15.0) : 1.0
        // 月光減衰: 月が明るいとき暗い星を減光
        let moonDimming = StarMapPalette.moonDimmingFactor(
            moonBrightness: moonBrightness, starMagnitude: magnitude
        )
        return opacity * brightness * extinction * moonDimming
    }

    /// 星の中心から描画が及ぶ最大距離（グロー込み）。
    static func drawExtent(magnitude: Double) -> Double {
        let radius = radius(magnitude: magnitude)
        if magnitude < outerGlowMagnitudeLimit { return radius * 5 }
        if magnitude < glowMagnitudeLimit { return radius * 3 }
        return radius
    }

    /// 中心 `point`・半径 `extent` の描画がキャンバスにかかりうるか（外接矩形で判定）。
    static func isPotentiallyVisible(_ point: CGPoint, extent: Double, canvasSize: CGSize) -> Bool {
        point.x + extent >= 0 && point.x - extent <= canvasSize.width
            && point.y + extent >= 0 && point.y - extent <= canvasSize.height
    }

    // MARK: Batching

    /// 不透明度の量子化段数。丸め誤差は最大 1/128（8bit 表示で 2 階調）に収まる。
    static let opacityLevelCount = 64
    /// B-V 色指数の量子化段数。隣接バケットの色差は各チャネル最大約 0.015（丸め誤差はその半分）。
    static let colorBucketCount = 128
    /// B-V 色指数を持たない星（白）のバケット。
    static let whiteColorBucket = colorBucketCount
    private static let minBV = -0.40
    private static let maxBV = 2.00
    private static let bvStep = (maxBV - minBV) / Double(colorBucketCount - 1)

    static func quantizedOpacityLevel(_ opacity: Double) -> Int {
        Int((min(max(opacity, 0), 1) * Double(opacityLevelCount)).rounded())
    }

    static func opacity(forLevel level: Int) -> Double {
        Double(level) / Double(opacityLevelCount)
    }

    /// `starColorForBV` と同じく範囲外の値は両端の色に寄せる。
    static func colorBucket(forBV bv: Double?) -> Int {
        guard let bv, bv.isFinite else { return whiteColorBucket }
        let clamped = min(max(bv, minBV), maxBV)
        return Int(((clamped - minBV) / bvStep).rounded())
    }

    static func representativeBV(forColorBucket bucket: Int) -> Double? {
        bucket == whiteColorBucket ? nil : minBV + Double(bucket) * bvStep
    }

    /// バケットごとの代表色（`colorBucket` で引く）。
    static let bucketColors: [Color] = (0...colorBucketCount).map {
        starColorForBV(representativeBV(forColorBucket: $0))
    }

    /// まとめ描きで星の円を近似する正多角形の頂点数。
    static let batchedDiscVertexCount = 16

    /// 面積が半径 1 の円と等しい正多角形の頂点（中心原点）。
    /// 多数の楕円を 1 つの Path にまとめると、レンダラーが楕円を粗い内接多角形に平坦化して
    /// 1 個ずつ塗る場合より星が暗く小さく見えるため、面積を合わせた多角形を自前で使う。
    static let batchedDiscUnitVertices: [CGPoint] = {
        let n = Double(batchedDiscVertexCount)
        let areaMatchingScale = (2 * Double.pi / (n * sin(2 * Double.pi / n))).squareRoot()
        return (0..<batchedDiscVertexCount).map { index in
            let angle = Double(index) * 2 * Double.pi / n
            return CGPoint(x: cos(angle) * areaMatchingScale, y: sin(angle) * areaMatchingScale)
        }
    }()

    /// まとめ描き用の Path に星 1 個ぶんの円盤（面積一致の正多角形）を追加する。
    static func addBatchedDisc(to path: inout Path, center: CGPoint, radius: Double) {
        let vertices = batchedDiscUnitVertices
        path.move(to: CGPoint(x: center.x + vertices[0].x * radius, y: center.y + vertices[0].y * radius))
        for vertex in vertices.dropFirst() {
            path.addLine(to: CGPoint(x: center.x + vertex.x * radius, y: center.y + vertex.y * radius))
        }
        path.closeSubpath()
    }

    static func batchKey(colorBucket: Int, opacityLevel: Int) -> Int {
        colorBucket * (opacityLevelCount + 1) + opacityLevel
    }

    static func components(ofBatchKey key: Int) -> (colorBucket: Int, opacityLevel: Int) {
        (key / (opacityLevelCount + 1), key % (opacityLevelCount + 1))
    }
}

enum StarMapPresentation {
    private static let azimuthNames = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]

    static func azimuthName(for degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % azimuthNames.count
        return L10n.tr(azimuthNames[index])
    }

    static func timeString(from minutes: Double) -> String {
        let hour = Int(minutes) / 60
        let minute = Int(minutes) % 60
        return String(format: "%02d:%02d", hour, minute)
    }
}
