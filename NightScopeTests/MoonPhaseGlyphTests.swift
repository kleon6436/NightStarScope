import XCTest
@testable import NightScope

final class MoonPhaseGlyphTests: XCTestCase {

    private let center = CGPoint(x: 50, y: 50)

    /// 輝面の重心の x 座標から中心の x 座標を引いた値。正なら右、負なら左が光る。
    private func litOffsetX(phase: Double, isSouthern: Bool) -> Double {
        let points = MoonPhaseGlyph.litPoints(phase: phase, isSouthern: isSouthern, center: center, radius: 10)
        XCTAssertFalse(points.isEmpty)
        let meanX = points.map { Double($0.x) }.reduce(0, +) / Double(points.count)
        return meanX - Double(center.x)
    }

    func test_northernHemisphere_waxingLitOnRight_waningLitOnLeft() {
        XCTAssertGreaterThan(litOffsetX(phase: 0.25, isSouthern: false), 0)
        XCTAssertLessThan(litOffsetX(phase: 0.75, isSouthern: false), 0)
    }

    func test_southernHemisphere_mirrorsLitSide() {
        XCTAssertLessThan(litOffsetX(phase: 0.25, isSouthern: true), 0)
        XCTAssertGreaterThan(litOffsetX(phase: 0.75, isSouthern: true), 0)
    }

    func test_newMoon_hasNoLitPolygon() {
        XCTAssertTrue(MoonPhaseGlyph.litPoints(phase: 0, isSouthern: false, center: center, radius: 10).isEmpty)
        XCTAssertTrue(MoonPhaseGlyph.litPoints(phase: 0, isSouthern: true, center: center, radius: 10).isEmpty)
    }
}
