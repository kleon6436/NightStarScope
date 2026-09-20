import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 今夜タブ上部に敷く「空」の背景。
///
/// 日没直後から天文薄明終了までの空色を、星図と同じパレット（`StarMapPalette.skyColor`）から
/// 取り出して縦方向に並べる。月明かりは入れない（`moonAltitude: 0`）。
/// アプリ内の空の色表現を 1 箇所に集約するため、独自のカラーリテラルは持たない。
struct SkyGradientBackground: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: Metrics.sunAltitudeStops.map {
                StarMapPalette.skyColor(sunAltitude: $0, moonAltitude: 0, moonPhase: 0)
            },
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            StarFieldCanvas()
                .frame(height: height * Metrics.starFieldHeightRatio)
        }
        .overlay(alignment: .bottom) {
            // 下端をシステム背景へ溶かし、スクロールしてくるカード類と地続きに見せる。
            LinearGradient(
                colors: [.clear, Metrics.systemBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * Metrics.bottomFadeRatio)
        }
        .frame(height: height)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private enum Metrics {
        /// 上端から下端へ、日没直後 → 天文薄明終了へ向かう太陽高度。
        /// 末尾を 2 回繰り返して、下半分をほぼ一定の暗い夜空にする。
        static let sunAltitudeStops: [Double] = [-2, -8, -14, -18, -18]
        static let starFieldHeightRatio: CGFloat = 0.45
        static let bottomFadeRatio: CGFloat = 0.32

        static var systemBackground: Color {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemBackground)
            #endif
        }
    }
}

// MARK: - Star Field

/// 固定シードの疑似乱数で星を散らす静的な星野。
/// 描画のたびに位置が変わるとちらつくため、`random()` は使わず毎回同じ配置を再現する。
private struct StarFieldCanvas: View {
    var body: some View {
        Canvas { context, size in
            var seed = Metrics.seed
            for _ in 0..<Metrics.starCount {
                let x = Self.nextUnit(&seed) * size.width
                let y = Self.nextUnit(&seed) * size.height
                let diameter = Metrics.minDiameter
                    + Self.nextUnit(&seed) * (Metrics.maxDiameter - Metrics.minDiameter)
                let opacity = Metrics.minOpacity
                    + Self.nextUnit(&seed) * (Metrics.maxOpacity - Metrics.minOpacity)
                let rect = CGRect(
                    x: x - diameter / 2,
                    y: y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
            }
        }
    }

    /// 線形合同法。0.0〜1.0 の値を決定的に返す。
    private static func nextUnit(_ seed: inout UInt64) -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(UInt64(1) << 53)
    }

    private enum Metrics {
        static let seed: UInt64 = 0x5EED_5A11
        static let starCount = 24
        static let minDiameter: Double = 1
        static let maxDiameter: Double = 2
        static let minOpacity: Double = 0.5
        static let maxOpacity: Double = 0.9
    }
}

#Preview {
    SkyGradientBackground(height: 420)
}
