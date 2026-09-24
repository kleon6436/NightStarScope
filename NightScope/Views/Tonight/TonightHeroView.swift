import SwiftUI

/// 今夜タブの主役。星空指数と一言の結論を、空のグラデーションの上に大きく置く。
/// - Note: 背景が常に暗い空のため、文字色はテーマに依存せず白系で固定する。
struct TonightHeroView: View {
    let index: StarGazingIndex?
    let verdict: NightVerdictPresentation
    let isCalculating: Bool

    /// 88pt は固定値だが、Dynamic Type には追従させる。
    @ScaledMetric(relativeTo: .largeTitle) private var scoreFontSize: CGFloat = Metrics.scoreFontSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            scoreRow

            Text(verdict.headline)
                .font(.title.weight(.bold))
                .foregroundStyle(Metrics.primaryTextColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(verdict.reason)
                .font(.subheadline)
                .foregroundStyle(Metrics.secondaryTextColor)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Score Row

    private var scoreRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(scoreText)
                .font(.system(size: scoreFontSize, weight: .thin, design: .default))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(Metrics.primaryTextColor)

            Text("/ 100")
                .font(.title3)
                .foregroundStyle(Metrics.secondaryTextColor)

            Spacer(minLength: 0)

            if let index {
                tierChip(for: index)
            } else if isCalculating {
                ProgressView()
                    .controlSize(.small)
                    .tint(Metrics.primaryTextColor)
            }
        }
    }

    private var scoreText: String {
        guard let index else { return Metrics.placeholderScore }
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
        static let placeholderScore = "—"
        static let primaryTextColor = Color.white
        static let secondaryTextColor = Color.white.opacity(0.72)
        static let chipBackgroundOpacity: Double = 0.18
        static let chipStrokeOpacity: Double = 0.35
        static let chipStrokeWidth: CGFloat = 1
    }
}
