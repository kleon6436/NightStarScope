import Foundation
import CoreLocation

/// 天文計算で共通に使う角度・暦の小さなユーティリティ。
enum AngleMath {
    /// J2000.0 元期（2000-01-01 12:00 TT）のユリウス日。
    static let j2000JulianDate: Double = 2451545.0

    /// 角度（度）を 0..<360 の範囲へ正規化する。
    static func normalizedDegrees(_ degrees: Double) -> Double {
        let normalized = degrees.truncatingRemainder(dividingBy: 360.0)
        return normalized < 0 ? normalized + 360.0 : normalized
    }

    /// 度をラジアンへ変換する。
    static func toRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180.0
    }

    /// ラジアンを度へ変換する。
    static func toDegrees(_ radians: Double) -> Double {
        radians * 180.0 / .pi
    }

    /// 角度（度）を度記号付きの表示文字列にする（例: "12.3°"）。
    static func degreesText(_ degrees: Double, fractionDigits: Int = 1) -> String {
        String(format: "%.\(fractionDigits)f°", degrees)
    }
}

extension CLLocationCoordinate2D {
    /// 緯度・経度が完全に一致するかを返す（許容誤差なし）。
    func isSameCoordinate(as other: CLLocationCoordinate2D) -> Bool {
        latitude == other.latitude && longitude == other.longitude
    }
}
