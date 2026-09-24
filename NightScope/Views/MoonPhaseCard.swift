import SwiftUI

/// 月相と月齢から観測への影響を示すカード。
struct MoonPhaseCard: View {
    let summary: NightSummary
    var style: SummaryCardStyle = .regular

    private var moonAgeDays: Double {
        summary.moonPhaseAtMidnight * 29.53
    }

    private var moonRecommendationText: String {
        summary.isMoonFavorable ? L10n.tr("撮影に適しています") : L10n.tr("月明かりに注意")
    }

    var body: some View {
        switch style {
        case .regular: regularBody
        case .compact: compactBody
        }
    }

    // MARK: - Compact

    private var compactBody: some View {
        MetricCard(icon: summary.moonPhaseIcon, title: "月の状態", tint: .indigo) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(summary.moonPhaseName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(L10n.format("月齢 %.1f日", moonAgeDays))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(moonRecommendationText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Regular

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            CardHeader(icon: summary.moonPhaseIcon, iconColor: .indigo, title: "月の状態")
            HStack(alignment: .center, spacing: Spacing.sm) {
                Image(systemName: summary.moonPhaseIcon)
                    .font(.system(size: CardVisual.moonIconSize))
                    .foregroundStyle(.indigo)
                    .summaryCardMetricVisualFrame()
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(summary.moonPhaseName)
                        .font(.headline)
                        .lineLimit(1)
                        .panelTooltip(summary.moonPhaseName)
                    HStack(spacing: Spacing.xs) {
                        Text("月齢")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(L10n.format("%.1f日", moonAgeDays))
                            .font(.body.monospacedDigit())
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    Text(moonRecommendationText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .panelTooltip(moonRecommendationText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: CardVisual.metricVisualHeight, alignment: .leading)
        }
        .contentCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        L10n.format(
            "月の状態: %@、月齢%.1f日。%@",
            summary.moonPhaseName,
            moonAgeDays,
            moonRecommendationText
        )
    }
}
