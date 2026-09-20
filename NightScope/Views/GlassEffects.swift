import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Liquid Glass Compatibility Helpers

extension View {
    /// `.glassEffect()` の互換ラッパー。iOS 18 / macOS 15 以降で動作する。
    /// iOS 26 / macOS 26 以上では Liquid Glass を適用し、それ以前は ultraThinMaterial にフォールバックする。
    @ViewBuilder
    func glassEffectCompat(in shape: RoundedRectangle) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
        }
    }

    /// iOS 26+ はシステム Liquid Glass NavBar に委ねる。それ以前は非表示にする。
    @ViewBuilder
    func adaptiveToolbarBackground() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            self
        } else {
            self.toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    /// `.backgroundExtensionEffect()` の互換ラッパー。
    /// iOS 26 / macOS 26 以降では背景をウィンドウ端まで引き伸ばし、それ以前は何もしない。
    @ViewBuilder
    func backgroundExtensionEffectCompat() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }

    /// `.buttonStyle(.glass)` の互換ラッパー。
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// `GlassEffectContainer` の互換ラッパー。
/// iOS 26 / macOS 26 以上では Liquid Glass コンテナを適用し、それ以前はそのまま描画する。
struct GlassEffectContainerCompat<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - GlassCard ViewModifier

struct GlassCardModifier: ViewModifier {
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
        #if os(macOS)
        background(Color(nsColor: .controlBackgroundColor), in: shape)
        #else
        background(Color(uiColor: .secondarySystemBackground), in: shape)
        #endif
    }

    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }

    func summaryCardMetricVisualFrame() -> some View {
        frame(width: CardVisual.width, height: CardVisual.metricVisualHeight, alignment: .center)
    }

    @ViewBuilder
    func panelTooltip(_ text: String?) -> some View {
#if os(macOS)
        if let text, !text.isEmpty {
            self.help(text)
        } else {
            self
        }
#else
        self
#endif
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

