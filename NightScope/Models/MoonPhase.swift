import Foundation
import CoreGraphics

/// 月相（0=新月, 0.25=上弦, 0.5=満月, 0.75=下弦）から名前・アイコン・輝面比・描画形状を導く共通ロジック。
enum MoonPhase {
    /// 根拠: illumination 0.15 未満は新月前後で、月明かりの影響が実用上無視できる。
    static let darkIlluminationThreshold = 0.15
    /// 根拠: illumination 0.6 以上は上弦〜満月域で、淡い天体の観測に明確な影響が出る。
    static let brightIlluminationThreshold = 0.6

    /// 月明かりの強さ（3 段階）。
    enum MoonlightLevel: Equatable {
        case low
        case moderate
        case high
    }

    static func moonlightLevel(illumination: Double) -> MoonlightLevel {
        if illumination < darkIlluminationThreshold { return .low }
        if illumination < brightIlluminationThreshold { return .moderate }
        return .high
    }

    static func name(phase: Double) -> String {
        switch phase {
        case 0..<0.04, 0.96...1: return L10n.tr("新月")
        case 0.04..<0.12: return L10n.tr("繊月")
        case 0.12..<0.22: return L10n.tr("三日月")
        case 0.22..<0.30: return L10n.tr("上弦の月")
        case 0.30..<0.46: return L10n.tr("十日月")
        case 0.46..<0.54: return L10n.tr("満月")
        case 0.54..<0.70: return L10n.tr("十六夜")
        case 0.70..<0.80: return L10n.tr("下弦の月")
        case 0.80..<0.96: return L10n.tr("有明月")
        default: return ""
        }
    }

    static func icon(phase: Double) -> String {
        switch phase {
        case 0..<0.04, 0.96...1: return AppIcons.Astronomy.moonPhaseNew
        case 0.04..<0.22: return AppIcons.Astronomy.moonPhaseWaxingCrescent
        case 0.22..<0.30: return AppIcons.Astronomy.moonPhaseFirstQuarter
        case 0.30..<0.46: return AppIcons.Astronomy.moonPhaseWaxingGibbous
        case 0.46..<0.54: return AppIcons.Astronomy.moonPhaseFull
        case 0.54..<0.70: return AppIcons.Astronomy.moonPhaseWaningGibbous
        case 0.70..<0.80: return AppIcons.Astronomy.moonPhaseLastQuarter
        default: return AppIcons.Astronomy.moonPhaseWaningCrescent
        }
    }

    /// 輝面比 (0〜1)。
    static func illumination(phase: Double) -> Double {
        (1 - cos(2 * .pi * phase)) / 2
    }

    /// 月の輝面を表す多角形（画面座標）を返す。
    /// `brightLimbScreenAngle`（rad, 画面座標で +x から +y 方向へ測る）を渡すと輝面の縁の中点がその向きになる。
    /// nil の場合は北半球の見え方に合わせ、満ちていく月（phase < 0.5）は右側、欠けていく月は左側が光る。
    /// 欠け際（ターミネーター）は楕円弧で表し、輝面方向の半径は radius × cos(2π·phase)。
    static func litPolygon(
        center: CGPoint,
        radius: Double,
        phase: Double,
        brightLimbScreenAngle: Double? = nil,
        segments: Int = 24
    ) -> [CGPoint] {
        let normalizedPhase = phase - floor(phase)
        let fraction = illumination(phase: normalizedPhase)
        guard fraction > 0.005, segments > 1 else { return [] }

        // 光っている側: 向きの指定があれば +x 側に作って回転する。
        // 指定がなければ満ちていく月は右 (+1)、欠けていく月は左 (-1)
        let litSide: Double
        if brightLimbScreenAngle != nil {
            litSide = 1
        } else {
            litSide = normalizedPhase < 0.5 ? 1 : -1
        }
        // ターミネーターの x 方向の比率。新月で +1（縁と一致）、上弦/下弦で 0、満月で -1。
        let terminatorScale = cos(2 * .pi * normalizedPhase)

        var points: [CGPoint] = []
        points.reserveCapacity((segments + 1) * 2)
        // 光っている側の縁（上 → 下）
        for step in 0...segments {
            let theta = -Double.pi / 2 + Double.pi * Double(step) / Double(segments)
            points.append(CGPoint(
                x: center.x + litSide * radius * cos(theta),
                y: center.y + radius * sin(theta)
            ))
        }
        // ターミネーター（下 → 上）
        for step in stride(from: segments, through: 0, by: -1) {
            let theta = -Double.pi / 2 + Double.pi * Double(step) / Double(segments)
            points.append(CGPoint(
                x: center.x + litSide * terminatorScale * radius * cos(theta),
                y: center.y + radius * sin(theta)
            ))
        }
        guard let brightLimbScreenAngle else { return points }
        let cosAngle = cos(brightLimbScreenAngle)
        let sinAngle = sin(brightLimbScreenAngle)
        return points.map { point in
            let dx = Double(point.x - center.x)
            let dy = Double(point.y - center.y)
            return CGPoint(
                x: center.x + dx * cosAngle - dy * sinAngle,
                y: center.y + dx * sinAngle + dy * cosAngle
            )
        }
    }
}
