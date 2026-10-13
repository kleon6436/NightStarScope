import XCTest
@testable import NightScope

final class MoonPhaseTests: XCTestCase {

    /// 月相名とアイコンの境界前後の期待値（リファクタ前の NightSummary の switch から固定）。
    private let expectations: [(phase: Double, name: String, icon: String)] = [
        (0.0, "新月", "moonphase.new.moon"),
        (0.0399, "新月", "moonphase.new.moon"),
        (0.04, "繊月", "moonphase.waxing.crescent"),
        (0.1199, "繊月", "moonphase.waxing.crescent"),
        (0.12, "三日月", "moonphase.waxing.crescent"),
        (0.2199, "三日月", "moonphase.waxing.crescent"),
        (0.22, "上弦の月", "moonphase.first.quarter"),
        (0.2999, "上弦の月", "moonphase.first.quarter"),
        (0.30, "十日月", "moonphase.waxing.gibbous"),
        (0.4599, "十日月", "moonphase.waxing.gibbous"),
        (0.46, "満月", "moonphase.full.moon"),
        (0.5399, "満月", "moonphase.full.moon"),
        (0.54, "十六夜", "moonphase.waning.gibbous"),
        (0.6999, "十六夜", "moonphase.waning.gibbous"),
        (0.70, "下弦の月", "moonphase.last.quarter"),
        (0.7999, "下弦の月", "moonphase.last.quarter"),
        (0.80, "有明月", "moonphase.waning.crescent"),
        (0.9599, "有明月", "moonphase.waning.crescent"),
        (0.96, "新月", "moonphase.new.moon"),
        (1.0, "新月", "moonphase.new.moon"),
    ]

    func test_name_matchesFixedTableAroundBoundaries() {
        for expectation in expectations {
            XCTAssertEqual(
                MoonPhase.name(phase: expectation.phase),
                L10n.tr(expectation.name),
                "phase=\(expectation.phase)"
            )
        }
    }

    func test_icon_matchesFixedTableAroundBoundaries() {
        for expectation in expectations {
            XCTAssertEqual(MoonPhase.icon(phase: expectation.phase), expectation.icon, "phase=\(expectation.phase)")
        }
    }

    func test_illumination_representativeValues() {
        XCTAssertEqual(MoonPhase.illumination(phase: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(MoonPhase.illumination(phase: 0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MoonPhase.illumination(phase: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(MoonPhase.illumination(phase: 0.75), 0.5, accuracy: 1e-12)
    }

    func test_moonlightLevel_switchesAtThresholds() {
        XCTAssertEqual(MoonPhase.moonlightLevel(illumination: 0.1499), .low)
        XCTAssertEqual(MoonPhase.moonlightLevel(illumination: 0.15), .moderate)
        XCTAssertEqual(MoonPhase.moonlightLevel(illumination: 0.5999), .moderate)
        XCTAssertEqual(MoonPhase.moonlightLevel(illumination: 0.6), .high)
    }

    func test_nightSummary_delegatesToMoonPhase() {
        let summary = NightSummary.placeholder
        XCTAssertEqual(summary.moonPhaseName, MoonPhase.name(phase: summary.moonPhaseAtMidnight))
        XCTAssertEqual(summary.moonPhaseIcon, MoonPhase.icon(phase: summary.moonPhaseAtMidnight))
        XCTAssertEqual(summary.moonIllumination, MoonPhase.illumination(phase: summary.moonPhaseAtMidnight))
    }
}
