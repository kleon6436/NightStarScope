import SwiftUI

@MainActor
/// 今日タブの表示状態と補助処理をまとめる。
struct iOSTodayViewModel {
    private let stateResolver = DetailContentStateResolver()

    func locationText(_ rawLocationName: String) -> String {
        rawLocationName.isEmpty ? L10n.tr("場所を選択") : rawLocationName
    }

    func headerTitle(for selectedDate: Date, timeZone: TimeZone) -> String {
        DateFormatters.yearMonthDayWeekdayStringWithoutWeekday(from: selectedDate, timeZone: timeZone)
    }

    func contentState(isCalculating: Bool, summary: NightSummary?) -> LoadableContentState {
        stateResolver.todayState(isCalculating: isCalculating, summary: summary)
    }

    func refreshAll(using detailViewModel: DetailViewModel) async {
        await detailViewModel.refreshExternalData()
    }
}

/// 今夜の観測サマリーを表示するメイン画面。
struct iOSTodayView: View {
    @ObservedObject var detailViewModel: DetailViewModel
    @ObservedObject var observationModePreference: ObservationModePreference
    private let viewModel = iOSTodayViewModel()
    @StateObject private var lightPollutionViewModel: StarGazingIndexCardViewModel
    @StateObject private var weatherViewModel = NightWeatherCardViewModel()
    @State private var presentedSheet: PresentedSheet?
    @State private var calendarDraftDate = Date()

    /// 詳細画面の ViewModel と観測モード設定を受け取る。
    init(
        detailViewModel: DetailViewModel,
        observationModePreference: ObservationModePreference = ObservationModePreference()
    ) {
        self.detailViewModel = detailViewModel
        self.observationModePreference = observationModePreference
        _lightPollutionViewModel = StateObject(
            wrappedValue: StarGazingIndexCardViewModel(
                lightPollutionService: detailViewModel.lightPollutionService
            )
        )
    }

    private var nightSummary: NightSummary? { detailViewModel.nightSummary }
    private var starGazingIndex: StarGazingIndex? { detailViewModel.displayedStarGazingIndex }
    private var weather: DayWeatherSummary? { detailViewModel.currentWeather }

    private var contentState: LoadableContentState {
        viewModel.contentState(isCalculating: detailViewModel.isCalculating, summary: nightSummary)
    }

    private var verdict: NightVerdictPresentation? {
        guard let summary = nightSummary else { return nil }
        return NightVerdictPresentation(
            index: starGazingIndex,
            summary: summary,
            weather: weather,
            hasReliableWeather: weather != nil && !detailViewModel.isCurrentWeatherCoverageIncomplete
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                SkyGradientBackground(height: IOSDesignTokens.Today.heroBackgroundHeight)
                    .ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        headerSection
                        contentSection
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.bottom, Spacing.sm)
                }
            }
            .refreshable {
                await viewModel.refreshAll(using: detailViewModel)
            }
            .adaptiveToolbarBackground()
            // 上端は常に暗い空なので、ナビゲーション領域も明色前提で描く。
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $presentedSheet) { sheet in
                sheetView(for: sheet)
            }
            .safeAreaInset(edge: .bottom) {
                // エラー表示を常設するため、下端の安全領域にオーバーレイを差し込む。
                DetailErrorOverlay(
                    weatherErrorMessage: detailViewModel.weatherErrorMessage,
                    hasLightPollutionError: detailViewModel.hasLightPollutionError,
                    retryWeatherAction: detailViewModel.retryWeatherInBackground,
                    retryLightPollutionAction: detailViewModel.retryLightPollutionInBackground
                )
            }
        }
    }

    // MARK: - サブビュー

    @ViewBuilder
    private var contentSection: some View {
        switch contentState {
        case .loading:
            loadingPlaceholder
        case .empty:
            emptyStateView
        case .content:
            if let summary = nightSummary {
                mainContent(summary: summary)
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "今夜の観測データがありません",
            systemImage: "moon.zzz",
            description: Text("場所や日付を変更して再度お試しください")
        )
    }

    @ViewBuilder
    private func mainContent(summary: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let verdict {
                TonightHeroView(
                    index: starGazingIndex,
                    verdict: verdict,
                    isCalculating: detailViewModel.isCalculating
                )
            }

            NightTimelineView(
                model: NightTimelineModel(
                    summary: summary,
                    nighttimeHours: weather?.nighttimeHours ?? []
                ),
                style: .onSky
            )

            summaryGrid(summary: summary)

            if let index = starGazingIndex {
                IndexBreakdownView(
                    index: index,
                    lightPollutionViewModel: lightPollutionViewModel,
                    layout: .row
                )
                .padding(IOSDesignTokens.Today.breakdownPadding)
                .cardSurface()
            }

            if weather != nil {
                WeatherAttributionBadge()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Spacing.xs)
            }
        }
    }

    private func summaryGrid(summary: NightSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: IOSDesignTokens.Today.gridSpacing
        ) {
            DarkTimeCard(summary: summary, weather: weather, style: .compact)

            MoonPhaseCard(summary: summary, style: .compact)

            NightWeatherCard(
                weather: weather,
                isLoading: detailViewModel.isWeatherLoading,
                isForecastOutOfRange: detailViewModel.isCurrentWeatherForecastOutOfRange,
                isCoverageIncomplete: detailViewModel.isCurrentWeatherCoverageIncomplete,
                errorMessage: weather == nil ? detailViewModel.weatherErrorMessage : nil,
                viewModel: weatherViewModel,
                style: .compact
            )

            MilkyWaySummaryCard(summary: summary, style: .compact)
        }
    }

    // MARK: - ヘッダー

    /// 空のグラデーションの上に載るため、ヘッダーの文字と装飾は白系で固定する。
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                    HStack(spacing: Spacing.xs / 2) {
                        Image(systemName: AppIcons.Navigation.locationPin)
                            .font(.footnote)
                            .accessibilityHidden(true)
                        Text(viewModel.locationText(detailViewModel.locationName))
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    .foregroundStyle(HeaderStyle.secondaryTextColor)

                    Text(
                        viewModel.headerTitle(
                            for: detailViewModel.displayedDate,
                            timeZone: detailViewModel.selectedTimeZone
                        )
                    )
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HeaderStyle.primaryTextColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                HStack(spacing: Spacing.xs / 2) {
                    calendarButton
                    settingsButton
                }
            }

            observationModeButton
        }
        .padding(.top, Spacing.xs)
    }

    private var observationModeButton: some View {
        Button {
            presentedSheet = .observationMode
        } label: {
            Label(
                L10n.tr(observationModePreference.mode.shortTitleKey),
                systemImage: observationModePreference.mode.iconSystemName
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(HeaderStyle.primaryTextColor)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 6)
                .background(HeaderStyle.capsuleFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("observation.mode.change"))
        .accessibilityHint(L10n.tr(observationModePreference.mode.descriptionKey))
    }

    private var calendarButton: some View {
        Button {
            calendarDraftDate = detailViewModel.selectedDate
            presentedSheet = .calendar
        } label: {
            Image(systemName: "calendar")
                .font(.headline)
                .frame(width: HeaderStyle.buttonGlyphSize, height: HeaderStyle.buttonGlyphSize)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .accessibilityLabel(L10n.tr("日付を選択"))
    }

    private var settingsButton: some View {
        Button {
            presentedSheet = .settings
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.headline)
                .frame(width: HeaderStyle.buttonGlyphSize, height: HeaderStyle.buttonGlyphSize)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .accessibilityLabel(L10n.tr("設定を開く"))
        .accessibilityHint(L10n.tr("アプリ全体の表示設定を変更します"))
    }

    private enum HeaderStyle {
        static let primaryTextColor = Color.white
        static let secondaryTextColor = Color.white.opacity(0.72)
        static let capsuleFill = Color.white.opacity(0.14)
        /// HIG の最小タップ領域。
        static let buttonSize: CGFloat = 44
        /// ガラスボタンはスタイル側で余白が付くため、グリフ枠は小さめにして全体を約 44pt の円に収める。
        static let buttonGlyphSize: CGFloat = 28
    }

    // MARK: - 読み込み中

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            placeholderBlock(height: IOSDesignTokens.Today.loadingHeroHeight)
            placeholderBlock(height: IOSDesignTokens.Today.loadingTimelineHeight)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: IOSDesignTokens.Today.gridSpacing
            ) {
                ForEach(0..<4, id: \.self) { _ in
                    placeholderBlock(height: IOSDesignTokens.Today.loadingGridCardHeight)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func placeholderBlock(height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .cardSurface(cornerRadius: Layout.cardCornerRadius)
    }

    @ViewBuilder
    private func sheetView(for sheet: PresentedSheet) -> some View {
        switch sheet {
        case .calendar:
            NavigationStack {
                CalendarView(
                    selectedDate: $calendarDraftDate,
                    timeZone: detailViewModel.selectedTimeZone
                )
                .navigationTitle("日付を選択")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            detailViewModel.selectedDate = calendarDraftDate
                            presentedSheet = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        case .observationMode:
            NavigationStack {
                iOSObservationModeSelectionView(observationModePreference: observationModePreference)
            }
            .presentationDetents([.medium])
        case .settings:
            iOSSettingsSheetView()
        }
    }
}

private extension iOSTodayView {
    /// sheet の種類を識別する。
    enum PresentedSheet: String, Identifiable {
        case calendar
        case observationMode
        case settings

        var id: String { rawValue }
    }
}

/// 観測モードの選択を行う sheet。
private struct iOSObservationModeSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var observationModePreference: ObservationModePreference

    var body: some View {
        List {
            ForEach(ObservationMode.allCases) { mode in
                Button {
                    observationModePreference.mode = mode
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: Spacing.xs) {
                            Label(L10n.tr(mode.titleKey), systemImage: mode.iconSystemName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if observationModePreference.mode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(L10n.tr(mode.descriptionKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(L10n.tr("observation.mode.sectionTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 設定画面を表示する sheet。
private struct iOSSettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

#Preview("Today - Loading") {
    iOSTodayView(detailViewModel: IOSPreviewFactory.detailViewModel(for: .loading))
}

#Preview("Today - Empty") {
    iOSTodayView(detailViewModel: IOSPreviewFactory.detailViewModel(for: .empty))
}

#Preview("Today - Content") {
    iOSTodayView(detailViewModel: IOSPreviewFactory.detailViewModel(for: .content))
}
