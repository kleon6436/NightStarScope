#if os(macOS)
import SwiftUI

/// 今後 9 日分の夜間条件を 1 行 1 夜の表で並べるビュー。
/// - Note: 表は天気データを含むため、スクロール位置に関わらず見えるよう見出し行にも帰属表示を置く。
struct UpcomingNightsGrid: View {
    @ObservedObject var viewModel: UpcomingNightsGridViewModel
    private let placeholderRowCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader
            content
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack(spacing: Spacing.xs) {
            Text("今後9日間の予報")
                .font(.title3.bold())
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.tr("今後9日間の予報を更新中"))
            }
            if let highlight = viewModel.bestNightHighlightText() {
                Text(highlight)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .panelTooltip(highlight)
            }
            Spacer()
            if !viewModel.isSelectedDateToday() {
                Button("今日") { viewModel.setSelectedDate(Date()) }
                    .glassButtonStyle()
                    .accessibilityLabel(L10n.tr("今日に移動"))
            }
            if !viewModel.weatherByDate.isEmpty {
                WeatherAttributionBadge(size: .headline)
            }
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var content: some View {
        let displayNights = viewModel.displayNights

        if viewModel.isLoading && displayNights.isEmpty {
            table(nights: (0..<placeholderRowCount).map(viewModel.placeholderNight(at:)))
                .redacted(reason: .placeholder)
                .allowsHitTesting(false)
        } else if displayNights.isEmpty {
            ContentUnavailableView(
                "予報データがありません",
                systemImage: AppIcons.Astronomy.moonZzz,
                description: Text("今後9日間の夜間予報を表示できませんでした")
            )
        } else {
            table(nights: displayNights)
        }
    }

    /// 列幅が固定のため、ウィンドウが狭いときだけ横スクロールへ退避する。
    private func table(nights: [NightSummary]) -> some View {
        ViewThatFits(in: .horizontal) {
            tableBody(nights: nights)
            ScrollView(.horizontal) {
                tableBody(nights: nights)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func tableBody(nights: [NightSummary]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            headerRow
            LazyVStack(alignment: .leading, spacing: TableMetrics.rowSpacing) {
                ForEach(Array(nights.enumerated()), id: \.offset) { offset, night in
                    row(night: night)
                    if offset < nights.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(minWidth: TableMetrics.minimumWidth, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: Spacing.xs) {
            Text("夜")
                .frame(width: LayoutMacOS.forecastDateColumn, alignment: .leading)
            Text("雲量")
                .frame(width: LayoutMacOS.forecastCloudColumn, alignment: .leading)
            Text("天気")
                .frame(width: LayoutMacOS.forecastWeatherColumn, alignment: .leading)
            Text("月")
                .frame(width: LayoutMacOS.forecastMoonColumn, alignment: .leading)
            Text("星空指数")
                .frame(
                    minWidth: LayoutMacOS.forecastIndexColumnMinWidth,
                    maxWidth: LayoutMacOS.forecastIndexColumnMaxWidth,
                    alignment: .leading
                )
            Text("暗夜開始")
                .frame(width: LayoutMacOS.forecastDarkColumn, alignment: .leading)
            Text("天の川ピーク")
                .frame(width: LayoutMacOS.forecastMilkyWayColumn, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Spacing.xs)
        .accessibilityHidden(true)
    }

    // MARK: - Row

    private func row(night: NightSummary) -> some View {
        let presentation = viewModel.forecastPresentation(for: night)
        let weather = viewModel.weatherSummary(for: night.date)
        let index = viewModel.starGazingIndex(for: night.date)
        let isSelected = viewModel.isDateSelected(night.date)

        return HStack(spacing: Spacing.xs) {
            dateCell(presentation: presentation)
            Text(presentation.cloudCoverText)
                .frame(width: LayoutMacOS.forecastCloudColumn, alignment: .leading)
            weatherCell(presentation: presentation, weather: weather)
            moonCell(night: night)
            indexCell(index: index)
            Text(presentation.darkStartText ?? TableMetrics.emptyValue)
                .frame(width: LayoutMacOS.forecastDarkColumn, alignment: .leading)
            Text(viewModel.milkyWayPeakText(night: night))
                .frame(width: LayoutMacOS.forecastMilkyWayColumn, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, Spacing.xs)
        .frame(height: LayoutMacOS.forecastRowHeight)
        .background { rowBackground(isSelected: isSelected) }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !viewModel.isLoading else { return }
            viewModel.setSelectedDate(night.date)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.cardAccessibilityLabel(night: night, weather: weather, index: index))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 選択行だけカード面を敷き、他の行は背景を持たない。
    private func rowBackground(isSelected: Bool) -> some View {
        Color.clear
            .cardSurface(cornerRadius: Layout.innerCornerRadius)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.innerCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: TableMetrics.selectionStrokeWidth)
            }
            .opacity(isSelected ? 1 : 0)
    }

    private func dateCell(presentation: ForecastCardPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
            Text(presentation.shortDateLabel)
            if let relative = presentation.relativeNightLabel {
                Text(relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: LayoutMacOS.forecastDateColumn, alignment: .leading)
    }

    private func weatherCell(
        presentation: ForecastCardPresentation,
        weather: DayWeatherSummary?
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: weather?.weatherIconName ?? "questionmark.circle")
                .foregroundStyle(
                    weather.map { viewModel.weatherIconColor(code: $0.representativeWeatherCode) } ?? .secondary
                )
                .accessibilityHidden(true)
            Text(presentation.weatherDetailText ?? TableMetrics.emptyValue)
        }
        .frame(width: LayoutMacOS.forecastWeatherColumn, alignment: .leading)
    }

    private func moonCell(night: NightSummary) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: night.moonPhaseIcon)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text(night.moonPhaseName)
            if !night.isMoonFavorable {
                Text("月明かりに注意")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: LayoutMacOS.forecastMoonColumn, alignment: .leading)
    }

    private func indexCell(index: StarGazingIndex?) -> some View {
        HStack(spacing: Spacing.xxs) {
            tierSquares(index: index)
            if let index {
                Text(index.label)
                    .foregroundStyle(index.tier.color)
            } else {
                Text("計算中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            minWidth: LayoutMacOS.forecastIndexColumnMinWidth,
            maxWidth: LayoutMacOS.forecastIndexColumnMaxWidth,
            alignment: .leading
        )
    }

    /// 5 段階評価を小さな四角で示す。星アイコンより横幅が安定し、行の高さを抑えられる。
    private func tierSquares(index: StarGazingIndex?) -> some View {
        HStack(spacing: TableMetrics.tierSquareSpacing) {
            ForEach(0..<5, id: \.self) { position in
                RoundedRectangle(cornerRadius: TableMetrics.tierSquareRadius, style: .continuous)
                    .fill(tierSquareStyle(index: index, position: position))
                    .frame(width: TableMetrics.tierSquareSize, height: TableMetrics.tierSquareSize)
            }
        }
        .accessibilityHidden(true)
    }

    private func tierSquareStyle(index: StarGazingIndex?, position: Int) -> AnyShapeStyle {
        guard let index, position < index.starCount else {
            return AnyShapeStyle(.quaternary)
        }
        return AnyShapeStyle(index.tier.color)
    }

    private enum TableMetrics {
        static let rowSpacing: CGFloat = 2
        static let selectionStrokeWidth: CGFloat = 1.5
        static let tierSquareSize: CGFloat = 9
        static let tierSquareSpacing: CGFloat = 3
        static let tierSquareRadius: CGFloat = 2
        static let emptyValue = "—"

        /// 固定列 + 可変列の最小幅 + 列間スペース + 行の左右パディング。
        static let minimumWidth: CGFloat =
            LayoutMacOS.forecastDateColumn
            + LayoutMacOS.forecastCloudColumn
            + LayoutMacOS.forecastWeatherColumn
            + LayoutMacOS.forecastMoonColumn
            + LayoutMacOS.forecastIndexColumnMinWidth
            + LayoutMacOS.forecastDarkColumn
            + LayoutMacOS.forecastMilkyWayColumn
            + Spacing.xs * 6
            + Spacing.xs * 2
    }
}
#endif
