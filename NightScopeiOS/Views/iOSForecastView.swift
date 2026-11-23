import SwiftUI

@MainActor
/// 予報タブの各行に必要な表示状態をまとめる。
struct iOSForecastRowModel {
    let night: NightSummary
    let index: StarGazingIndex?
    let weather: DayWeatherSummary?
    let isReliableWeather: Bool
    let hasPartialWeather: Bool
    let isForecastOutOfRange: Bool
    let hasWeatherLoadError: Bool
    let isSelected: Bool
    let accessibilityLabel: String
    /// アプリ全体の「今夜」にあたる観測日。「今夜」「明夜」の判定に使う。
    var currentObservationDate: Date? = nil

    /// 短縮日付や薄明開始時刻など、カード表示用の文言。
    var presentation: ForecastCardPresentation {
        ForecastCardPresentation(
            night: night,
            weather: weather,
            timeZone: night.timeZone,
            isReliableWeather: isReliableWeather,
            hasPartialWeather: hasPartialWeather,
            isForecastOutOfRange: isForecastOutOfRange,
            hasWeatherLoadError: hasWeatherLoadError,
            currentObservationDate: currentObservationDate
        )
    }
}

@MainActor
/// 予報タブの表示状態計算と選択操作をまとめる。
struct iOSForecastViewModel {
    // 状態判定は詳細画面と同じ resolver に寄せて、分岐を二重管理しない。
    private let stateResolver = DetailContentStateResolver()

    func displayState(hasDisplayNights: Bool, isUpcomingLoading: Bool) -> LoadableContentState {
        stateResolver.forecastState(
            hasDisplayNights: hasDisplayNights,
            isUpcomingLoading: isUpcomingLoading
        )
    }

    /// 一覧の行値（入力が変わったときだけ判定済み）から、予報タブの行モデルを作る。
    func rowModel(for row: UpcomingNightRow) -> iOSForecastRowModel {
        iOSForecastRowModel(
            night: row.night,
            index: row.index,
            weather: row.weather,
            isReliableWeather: row.isReliableWeather,
            hasPartialWeather: row.hasPartialWeather,
            isForecastOutOfRange: row.isForecastOutOfRange,
            hasWeatherLoadError: row.hasWeatherLoadError,
            isSelected: row.isSelected,
            accessibilityLabel: row.accessibilityLabel,
            currentObservationDate: row.currentObservationDate
        )
    }

    func selectNight(_ date: Date, using gridViewModel: UpcomingNightsGridViewModel, selectedTab: Binding<Int>) {
        gridViewModel.setSelectedDate(date)
        // 予報行の選択後は今夜タブへ戻して、詳細をすぐ確認できるようにする。
        selectedTab.wrappedValue = 0
    }
}

/// 9日予報タブの一覧画面。
struct iOSForecastView: View {
    @ObservedObject var detailViewModel: DetailViewModel
    @Binding var selectedTab: Int
    private let viewModel = iOSForecastViewModel()
    @StateObject private var gridViewModel: UpcomingNightsGridViewModel

    /// 詳細画面の ViewModel とタブ選択状態を受け取る。
    init(detailViewModel: DetailViewModel, selectedTab: Binding<Int>) {
        self.detailViewModel = detailViewModel
        self._selectedTab = selectedTab
        self._gridViewModel = StateObject(wrappedValue: UpcomingNightsGridViewModel(detailViewModel: detailViewModel))
    }

    private var displayState: LoadableContentState {
        viewModel.displayState(
            hasDisplayNights: !gridViewModel.displayNights.isEmpty,
            isUpcomingLoading: detailViewModel.isUpcomingLoading || gridViewModel.isLoading
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    headerSection
                    contentByState
                    MeteorShowerCalendarView(
                        selectedDate: detailViewModel.selectedDate,
                        timeZone: detailViewModel.selectedTimeZone,
                        today: detailViewModel.currentObservationDate()
                    )
                    if let location = detailViewModel.nightSummary?.location {
                        PlanetVisibilityView(
                            selectedDate: detailViewModel.selectedDate,
                            location: location,
                            timeZone: detailViewModel.selectedTimeZone,
                            isTonight: ObservationTimeZone.isDate(
                                detailViewModel.selectedDate,
                                inSameDayAs: detailViewModel.currentObservationDate(),
                                timeZone: detailViewModel.selectedTimeZone
                            )
                        )
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.sm)
            }
            .refreshable {
                await detailViewModel.refreshWeather()
                await detailViewModel.refreshForecast()
            }
        }
    }

    private var headerSection: some View {
        iOSTabHeaderView(
            title: L10n.tr("9日予報"),
            horizontalPadding: Spacing.xs
        ) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: AppIcons.Navigation.locationPin)
                        .font(.subheadline)
                    Text(detailViewModel.locationName.isEmpty ? "場所を選択" : detailViewModel.locationName)
                        .font(.subheadline)
                        .lineLimit(1)
                }

                Text("今後9日間の夜空の見通し")
                    .font(.subheadline)
                    .lineLimit(2)
            }
        } trailing: {
            if detailViewModel.isUpcomingLoading || gridViewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.tr("9日予報を更新中"))
            }
        }
    }

    @ViewBuilder
    private var contentByState: some View {
        switch displayState {
        case .loading:
            loadingView
        case .empty:
            emptyStateView
        case .content:
            forecastList
        }
    }

    private var loadingView: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
            Text("予報を計算中...")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: IOSDesignTokens.Forecast.loadingMinHeight)
        .iOSMaterialPanel()
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("予報データがありません", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("9日間の予報データを計算できませんでした")
        } actions: {
            Button("再試行") {
                detailViewModel.retryForecastInBackground()
            }
        }
    }

    private var forecastList: some View {
        let display = gridViewModel.display

        return VStack(alignment: .leading, spacing: IOSDesignTokens.Forecast.calloutSpacing) {
            if let pick = bestNightPick(in: display),
               let pickRow = display.rows.first(where: { $0.id == pick.summary.date }) {
                bestNightCallout(pick: pick, row: pickRow)
            }
            LazyVStack(alignment: .leading, spacing: IOSDesignTokens.Forecast.rowSpacing) {
                ForEach(display.rows) { row in
                    forecastRow(for: row)
                }
            }
            // 天気データを含む一覧の直下に帰属表示を置く（WeatherKit 利用規約）。
            WeatherAttributionBadge()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 強調する価値のある夜。採点済みの候補が 1 夜だけの一覧では「いちばんの夜」に意味がないため出さない。
    private func bestNightPick(in display: UpcomingNightsDisplay) -> BestNightPick? {
        guard display.scoredNightCount >= IOSDesignTokens.Forecast.calloutMinimumNightCount,
              let pick = display.bestNightPick,
              pick.isWorthHighlighting else { return nil }
        return pick
    }

    /// 一覧の先頭で「この期間の狙い目」を 1 枚に要約するカード。タップ操作は行と同じ。
    private func bestNightCallout(pick: BestNightPick, row: UpcomingNightRow) -> some View {
        let rowModel = viewModel.rowModel(for: row)
        let presentation = rowModel.presentation
        let timeText = pick.windowText ?? presentation.darkStartText
        let headline = [presentation.shortDateLabel, timeText]
            .compactMap { $0 }
            .joined(separator: " ")
        let calloutShape = RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)

        return Button {
            viewModel.selectNight(pick.summary.date, using: gridViewModel, selectedTab: $selectedTab)
        } label: {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: AppIcons.Astronomy.starFill)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: IOSDesignTokens.NightRow.tightLineSpacing) {
                    Text(L10n.tr("この9日でいちばんの狙い目"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(headline)
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(IOSDesignTokens.NightRow.metadataMinimumScaleFactor)
                    Text(pick.reasonText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(IOSDesignTokens.NightRow.metadataMinimumScaleFactor)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.cardPadding)
            .background(calloutShape.fill(Color.accentColor.opacity(IOSDesignTokens.Forecast.calloutTintOpacity)))
            .cardSurface()
            .overlay(
                calloutShape.stroke(
                    Color.accentColor.opacity(IOSDesignTokens.Forecast.calloutStrokeOpacity),
                    lineWidth: IOSDesignTokens.Forecast.calloutStrokeWidth
                )
            )
        }
        .buttonStyle(ForecastRowButtonStyle())
        .accessibilityLabel(rowModel.accessibilityLabel)
        .accessibilityHint(L10n.tr("タップして今夜タブで詳細を表示"))
    }

    private func forecastRow(for row: UpcomingNightRow) -> some View {
        let rowModel = viewModel.rowModel(for: row)

        return Button {
            viewModel.selectNight(rowModel.night.date, using: gridViewModel, selectedTab: $selectedTab)
        } label: {
            iOSNightCardRow(
                night: rowModel.night,
                index: rowModel.index,
                weather: rowModel.weather,
                isReliableWeather: rowModel.isReliableWeather,
                hasPartialWeather: rowModel.hasPartialWeather,
                isForecastOutOfRange: rowModel.isForecastOutOfRange,
                hasWeatherLoadError: rowModel.hasWeatherLoadError,
                isSelected: rowModel.isSelected,
                showsHourlyStrip: rowModel.isSelected,
                currentObservationDate: rowModel.currentObservationDate
            )
        }
        .buttonStyle(ForecastRowButtonStyle())
        .accessibilityLabel(rowModel.accessibilityLabel)
        .accessibilityHint(L10n.tr("タップして今夜タブで詳細を表示"))
        .accessibilityAddTraits(rowModel.isSelected ? .isSelected : [])
    }
}

private struct ForecastRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? .none : .spring(duration: 0.2), value: configuration.isPressed)
    }
}

#Preview("Forecast - Loading") {
    iOSForecastView(
        detailViewModel: IOSPreviewFactory.detailViewModel(for: .loading),
        selectedTab: .constant(1)
    )
}

#Preview("Forecast - Empty") {
    iOSForecastView(
        detailViewModel: IOSPreviewFactory.detailViewModel(for: .empty),
        selectedTab: .constant(1)
    )
}

#Preview("Forecast - Content") {
    iOSForecastView(
        detailViewModel: IOSPreviewFactory.detailViewModel(for: .content),
        selectedTab: .constant(1)
    )
}
