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
    /// macOS 星空マップ下部バーの操作行の高さ。
    static let macControlRowHeight: CGFloat = 28
    /// macOS 星空マップ下部バーのステータスチップ間隔。
    static let macStatusChipSpacing: CGFloat = 16
    /// Slider のつまみ半径ぶんヒートバーを内側へ寄せる量。
    static let macHeatBarTrackInset: CGFloat = 10

    static func clampedFOV(_ value: Double) -> Double {
        max(minFOV, min(maxFOV, value))
    }
}

enum StarMapPalette {
    static let canvasBackground = Color(red: 0.02, green: 0.04, blue: 0.12)
    static let groundFill = Color(red: 0.06, green: 0.04, blue: 0.02)
    static let meteorAccent = Color(red: 0.4, green: 1.0, blue: 0.7)

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
