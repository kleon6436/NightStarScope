import SwiftUI

/// Bortle スケール（1〜9）に対応するアプリ共通のカラーランプ。
/// サイドバー・ダッシュボード・光害マップタイルはすべてこの 1 本のランプを使う。
enum BortleScale {

    /// Bortle クラス（1〜9）ごとの RGB 成分（0〜1）。
    private static let ramp: [(r: Double, g: Double, b: Double)] = [
        (0.10, 0.10, 0.18),  // 1
        (0.17, 0.24, 0.42),  // 2
        (0.18, 0.44, 0.69),  // 3
        (0.25, 0.62, 0.35),  // 4
        (0.62, 0.83, 0.35),  // 5
        (0.91, 0.83, 0.30),  // 6
        (0.94, 0.64, 0.23),  // 7
        (0.91, 0.33, 0.25),  // 8
        (0.95, 0.91, 0.89)   // 9
    ]

    /// Bortle クラスを四捨五入し 1...9 に丸めた RGB 成分（0〜1）を返す。
    static func rgb(for bortleClass: Double) -> (r: Double, g: Double, b: Double) {
        // NaN / 極端値でも Int 変換がトラップしないよう Double のまま 1...9 に丸める
        let clamped = min(9, max(1, bortleClass.rounded()))
        return ramp[Int(clamped) - 1]
    }

    /// Bortle クラスに対応する表示色。
    static func color(for bortleClass: Double) -> Color {
        let components = rgb(for: bortleClass)
        return Color(red: components.r, green: components.g, blue: components.b)
    }
}
