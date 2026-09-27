import SwiftUI

// MARK: - Platform Colors

extension Color {
    #if os(macOS)
    /// ウィンドウ全体の背景色（macOS: windowBackgroundColor / iOS: systemBackground）。
    static var platformWindowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// カードなど一段上のサーフェス色（macOS: controlBackgroundColor / iOS: secondarySystemBackground）。
    static var platformSecondaryBackground: Color { Color(nsColor: .controlBackgroundColor) }
    #else
    /// ウィンドウ全体の背景色（macOS: windowBackgroundColor / iOS: systemBackground）。
    static var platformWindowBackground: Color { Color(uiColor: .systemBackground) }
    /// カードなど一段上のサーフェス色（macOS: controlBackgroundColor / iOS: secondarySystemBackground）。
    static var platformSecondaryBackground: Color { Color(uiColor: .secondarySystemBackground) }
    #endif
}

// MARK: - Platform View Modifiers

extension View {
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

    /// iOS ではナビゲーションタイトルをインライン表示にする。macOS では何もしない。
    func inlineNavigationTitleDisplay() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// macOS ではホバー時のヘルプ表示を付ける。iOS では何もしない。
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

    /// 行の詳細を、macOS はホバー中のツールチップ、iOS はタップで開くシートで見せる。
    /// - Note: ホバー中の背景と `zIndex` は呼び出し側で `isHovered` を見て付ける。
    func hoverTooltipOrTapSheet<Tooltip: View, Sheet: View>(
        isHovered: Binding<Bool>,
        @ViewBuilder tooltip: @escaping () -> Tooltip,
        @ViewBuilder sheet: @escaping () -> Sheet
    ) -> some View {
        modifier(HoverTooltipOrTapSheetModifier(isHovered: isHovered, tooltip: tooltip, sheet: sheet))
    }
}

private struct HoverTooltipOrTapSheetModifier<Tooltip: View, Sheet: View>: ViewModifier {
    @Binding var isHovered: Bool
    let tooltip: () -> Tooltip
    let sheet: () -> Sheet
    @State private var isSheetPresented = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: .bottomTrailing) {
                if isHovered {
                    tooltip()
                }
            }
        #else
        content
            .onTapGesture { isSheetPresented = true }
            .sheet(isPresented: $isSheetPresented, content: sheet)
        #endif
    }
}
