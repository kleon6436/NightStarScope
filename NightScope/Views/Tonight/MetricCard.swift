import SwiftUI

/// 要約カードの表示密度。
/// `.regular` は従来どおりの 1 列表示、`.compact` はグリッドに並べる小型表示。
enum SummaryCardStyle {
    case regular
    case compact

    /// 本文 1 行あたりの行数上限。
    /// `.compact` は狭いグリッド幅に置かれ、既定より大きな文字サイズでは 1 行に収まらないため折り返しを許す。
    /// 既定の文字サイズ（macOS は常にこれ）では 1 行のままにして、グリッドの高さを変えない。
    func textLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int {
        switch self {
        case .regular: return 1
        case .compact: return dynamicTypeSize > .large ? 3 : 1
        }
    }
}

/// `MetricCard` はジェネリクスのため、定数はファイルスコープへ置く。
private enum MetricCardMetrics {
    static let padding: CGFloat = 14
    static let iconSize: CGFloat = 14
}

/// アイコンの寸法は見出しの caption に合わせて Dynamic Type に追従させる。
private struct MetricCardIcon: View {
    let systemName: String
    let tint: Color
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = MetricCardMetrics.iconSize

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
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
                MetricCardIcon(systemName: icon, tint: tint)
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
