import XCTest
import SwiftUI
@testable import NightScope

/// 今夜タブの共有ビューが持つ純粋ロジックを検証する。
/// 描画そのものは対象外で、値の写し取り（平均・ラベル・スコア表記）だけを見る。
@MainActor
final class TonightViewsTests: XCTestCase {

    // MARK: - SummaryCardStyle

    func test_summaryCardStyle_hasRegularAndCompact() {
        XCTAssertNotEqual(SummaryCardStyle.regular, SummaryCardStyle.compact)
    }

    // MARK: - NightTimelineView.averageCloudPercent

    func test_averageCloudPercent_isNilWhenNoSamples() {
        XCTAssertNil(NightTimelineView.averageCloudPercent(samples: []))
    }

    func test_averageCloudPercent_returnsMeanOfSamples() throws {
        let samples: [(fraction: Double, cloudCoverPercent: Double, precipitationMM: Double)] = [
            (fraction: 0.0, cloudCoverPercent: 20, precipitationMM: 0),
            (fraction: 0.5, cloudCoverPercent: 40, precipitationMM: 0),
            (fraction: 1.0, cloudCoverPercent: 60, precipitationMM: 1.5)
        ]
        let average = try XCTUnwrap(NightTimelineView.averageCloudPercent(samples: samples))
        XCTAssertEqual(average, 40, accuracy: 0.0001)
    }

    // MARK: - IndexBreakdownView.items

    func test_breakdownItems_mapScoresToLabelledValues() {
        let items = IndexBreakdownView.items(
            for: makeTestIndex(
                milkyWayScore: 20,
                constellationScore: 25,
                weatherScore: 32,
                lightPollutionScore: 18
            ),
            lightPollutionStatusText: "取得中..."
        )

        // テストホストのロケールに依存しないよう、期待値も翻訳経由で組み立てる。
        XCTAssertEqual(
            items.map(\.label),
            [L10n.tr("星空"), L10n.tr("気象"), L10n.tr("光害")]
        )
        XCTAssertEqual(items.map(\.valueText), ["25/30", "32/40", "18/30"])
        XCTAssertEqual(items.map(\.maxScore), [30, 40, 30])
    }

    func test_breakdownItems_fallBackToStatusTextWhenDataMissing() {
        let items = IndexBreakdownView.items(
            for: makeTestIndex(
                milkyWayScore: 20,
                constellationScore: 25,
                weatherScore: 32,
                lightPollutionScore: 18,
                hasWeatherData: false,
                hasLightPollutionData: false
            ),
            lightPollutionStatusText: "取得失敗"
        )

        XCTAssertEqual(items[1].valueText, L10n.tr("データなし"))
        XCTAssertEqual(items[2].valueText, "取得失敗")
        XCTAssertNil(items[1].score)
        XCTAssertNil(items[2].score)
    }
}
