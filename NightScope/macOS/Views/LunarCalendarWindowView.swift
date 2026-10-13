import SwiftUI
import AppKit

/// macOS の月齢カレンダーウィンドウ。左にグリッド、右に選んだ夜の詳細を置く。
struct LunarCalendarWindowView: View {
    @ObservedObject var viewModel: LunarCalendarViewModel
    @Environment(\.openWindow) private var openWindow

    static let windowID = "lunarCalendar"
    static let mainWindowID = "main"

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ScrollView {
                LunarCalendarView(viewModel: viewModel)
                    .padding(Spacing.md)
            }
            .frame(minWidth: 380)

            Group {
                if let day = viewModel.selectedDay {
                    LunarNightDetailPanel(
                        day: day,
                        timeZone: viewModel.timeZone,
                        isSouthernHemisphere: viewModel.isSouthernHemisphere,
                        onOpenNight: openNight
                    )
                }
            }
            .frame(width: 240)
            .padding([.top, .trailing], Spacing.md)
        }
        .frame(minWidth: 640, minHeight: 520)
        .navigationTitle(L10n.tr("月齢カレンダー"))
    }

    private func openNight(_ night: Date) {
        viewModel.openNight(night)
        // WindowGroup への openWindow は毎回新しいウィンドウを作るため、既存の主ウィンドウがあれば前面に出すだけにする。
        if let mainWindow = NSApp.windows.first(where: { Self.isMainWindow(identifier: $0.identifier?.rawValue) }) {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Self.mainWindowID)
        }
    }

    /// SwiftUI は WindowGroup(id:) のウィンドウに「<id>-AppWindow-<連番>」形式の識別子を付ける。
    static func isMainWindow(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == mainWindowID || identifier.hasPrefix(mainWindowID + "-")
    }
}
