import SwiftUI

/// 今夜タブの主役。星空指数と一言の結論を、空のグラデーションの上に大きく置く。
/// - Note: 背景が常に暗い空のため、文字色はテーマに依存せず白系で固定する。
struct TonightHeroView: View {
    let index: StarGazingIndex?
    let verdict: NightVerdictPresentation
    let isCalculating: Bool

    /// 88pt は固定値だが、Dynamic Type には追従させる。
    @ScaledMetric(relativeTo: .largeTitle) private var scoreFontSize: CGFloat = Metrics.scoreFontSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// アクセシビリティ文字サイズでは、点数と評価チップを横に並べると評価が省略されるため縦に積む。
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    /// 大きな文字では 2 行に収まらない文言があるため、行数の上限を広げる。
    private var textLineLimit: Int { isAccessibilitySize ? Metrics.accessibilityTextLineLimit : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            scoreRow

            Text(verdict.headline)
                .font(.title.weight(.bold))
                .foregroundStyle(Metrics.primaryTextColor)
                .lineLimit(textLineLimit)
                .minimumScaleFactor(0.8)

            Text(verdict.reason)
                .font(.subheadline)
                .foregroundStyle(Metrics.secondaryTextColor)
                .lineLimit(textLineLimit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Score Row

    @ViewBuilder
    private var scoreRow: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    scoreText
                    maxScoreText
                }
                scoreStatus
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                scoreText
                maxScoreText
                Spacer(minLength: 0)
                scoreStatus
            }
        }
    }

    private var scoreText: some View {
        Text(scoreValueText)
            .font(.system(size: scoreFontSize, weight: .thin, design: .default))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(Metrics.primaryTextColor)
    }

    private var maxScoreText: some View {
        Text("/ 100")
            .font(.title3)
            .foregroundStyle(Metrics.secondaryTextColor)
    }

    @ViewBuilder
    private var scoreStatus: some View {
        if let index {
            tierChip(for: index)
        } else if isCalculating {
            ProgressView()
                .controlSize(.small)
                .tint(Metrics.primaryTextColor)
        }
    }

    private var scoreValueText: String {
        guard let index else { return Placeholder.dash }
        return "\(index.score)"
    }

    private func tierChip(for index: StarGazingIndex) -> some View {
        let color = index.tier.color
        return Text(index.label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(color.opacity(Metrics.chipBackgroundOpacity), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    color.opacity(Metrics.chipStrokeOpacity),
                    lineWidth: Metrics.chipStrokeWidth
                )
            }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        guard let index else {
            return "\(verdict.headline)。\(verdict.reason)"
        }
        return L10n.format(
            "星空指数 %d点、%@。%@",
            index.score,
            index.label,
            verdict.headline
        )
    }

    private enum Metrics {
        static let scoreFontSize: CGFloat = 88
        static let primaryTextColor = Color.white
        static let secondaryTextColor = Color.white.opacity(0.72)
        static let chipBackgroundOpacity: Double = 0.18
        static let chipStrokeOpacity: Double = 0.35
        static let chipStrokeWidth: CGFloat = 1
        static let accessibilityTextLineLimit = 4
    }
}
