import SwiftUI

/// 月齢カレンダータブ。月ごとのグリッドと、選んだ夜の詳細を縦に並べる。
struct iOSLunarCalendarView: View {
    @ObservedObject var viewModel: LunarCalendarViewModel
    @Binding var selectedTab: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    iOSTabHeaderView(title: L10n.tr("月齢カレンダー"), horizontalPadding: Spacing.xs) {
                        Text("月の満ち欠けと月明かりの少ない夜")
                            .font(.subheadline)
                            .lineLimit(2)
                    } trailing: {
                        EmptyView()
                    }
                    LunarCalendarView(viewModel: viewModel)
                        .contentCard()
                    if let day = viewModel.selectedDay {
                        LunarNightDetailPanel(
                            day: day,
                            timeZone: viewModel.timeZone,
                            isSouthernHemisphere: viewModel.isSouthernHemisphere,
                            onOpenNight: openNight
                        )
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.sm)
            }
            .dynamicTypeSize(...LunarCalendarStyle.maximumTypeSize)
            .adaptiveToolbarBackground()
        }
    }

    private func openNight(_ night: Date) {
        viewModel.openNight(night)
        // 選んだ夜の詳細をすぐ確認できるよう、空模様タブへ移る。
        selectedTab = 0
    }
}
