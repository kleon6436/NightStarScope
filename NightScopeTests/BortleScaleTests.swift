import XCTest
@testable import NightScope

final class BortleScaleTests: XCTestCase {

    // MARK: - Clamping

    func test_rgb_clampsBelowRangeToClassOne() {
        let expected = BortleScale.rgb(for: 1)

        // 0.5 は四捨五入だけで 1 になるため、クランプの検証には使えない。
        for value in [-1.0, 0.4] {
            XCTAssertEqual(BortleScale.rgb(for: value).r, expected.r, accuracy: 0.0001)
            XCTAssertEqual(BortleScale.rgb(for: value).g, expected.g, accuracy: 0.0001)
            XCTAssertEqual(BortleScale.rgb(for: value).b, expected.b, accuracy: 0.0001)
        }
    }

    func test_rgb_clampsAboveRangeToClassNine() {
        let expected = BortleScale.rgb(for: 9)

        XCTAssertEqual(BortleScale.rgb(for: 12).r, expected.r, accuracy: 0.0001)
        XCTAssertEqual(BortleScale.rgb(for: 12).g, expected.g, accuracy: 0.0001)
        XCTAssertEqual(BortleScale.rgb(for: 12).b, expected.b, accuracy: 0.0001)
    }

    // MARK: - Rounding

    func test_rgb_roundsToNearestClass() {
        let four = BortleScale.rgb(for: 4)
        let five = BortleScale.rgb(for: 5)

        XCTAssertEqual(BortleScale.rgb(for: 4.4).r, four.r, accuracy: 0.0001)
        XCTAssertEqual(BortleScale.rgb(for: 4.4).g, four.g, accuracy: 0.0001)
        XCTAssertEqual(BortleScale.rgb(for: 4.6).r, five.r, accuracy: 0.0001)
        XCTAssertEqual(BortleScale.rgb(for: 4.6).g, five.g, accuracy: 0.0001)
    }

    // MARK: - Ramp Direction

    /// クラスが上がるほど赤成分が強くなる（= 暖色寄りになる）ことを確認する。
    /// クラス 8 は彩度を落とした赤のため 7 をわずかに下回る。
    /// そのため 4→7 は単調増加、8 は 4 より暖色であることを確認する。
    func test_rgb_redChannelGetsWarmerWithHigherClass() {
        let reds = (4...7).map { BortleScale.rgb(for: Double($0)).r }

        for (lower, higher) in zip(reds, reds.dropFirst()) {
            XCTAssertLessThan(lower, higher)
        }

        XCTAssertGreaterThan(BortleScale.rgb(for: 8).r, BortleScale.rgb(for: 4).r)
    }
}
