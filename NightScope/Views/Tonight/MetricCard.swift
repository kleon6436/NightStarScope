import SwiftUI

/// 要約カードの表示密度。
/// `.regular` は従来どおりの 1 列表示、`.compact` はグリッドに並べる小型表示。
enum SummaryCardStyle {
    case regular
    case compact
}

/// `MetricCard` はジェネリクスのため、定数はファイルスコープへ置く。
private enum MetricCardMetrics {
    static let padding: CGFloat = 14
    static let iconSize: CGFloat = 14
}

/// `.compact` の要約カード共通の器。
/// ヘッダー（小さいアイコン + ラベル）と本文だけを持ち、左側のゲージ類は載せない。
struct MetricCard<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: MetricCardMetrics.iconSize))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MetricCardMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}
