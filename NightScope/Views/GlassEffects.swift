import SwiftUI

// MARK: - ContentCard ViewModifier

/// カード共通の余白とサーフェスをまとめる。ガラス（Material）は使わない。
struct ContentCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface()
    }
}

extension View {
    /// コンテンツ層の共通サーフェス。不透明なカード背景を角丸で敷く。
    /// ガラス（Material）はシェル層専用とし、カード類はこちらに統一する。
    func cardSurface(cornerRadius: CGFloat = Layout.cardCornerRadius) -> some View {
        opaqueCardBackground(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func opaqueCardBackground<S: Shape>(in shape: S) -> some View {
        background(Color.platformSecondaryBackground, in: shape)
    }

    /// コンテンツ層のカード共通スタイル（余白 + 不透明サーフェス）。
    func contentCard() -> some View {
        modifier(ContentCardModifier())
    }

    func summaryCardMetricVisualFrame() -> some View {
        frame(width: CardVisual.width, height: CardVisual.metricVisualHeight, alignment: .center)
    }
}

// MARK: - CardHeader

/// 全カード共通のヘッダー（SF Symbol アイコン + カテゴリラベル）
struct CardHeader: View {
    let icon: String
    let iconColor: Color
    let title: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.title3)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

