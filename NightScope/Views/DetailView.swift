import SwiftUI

/// 選択中の日付に対する詳細情報をまとめるメイン詳細ビュー。
struct DetailView: View {
    @ObservedObject var viewModel: DetailViewModel
    @ObservedObject var observationModePreference: ObservationModePreference
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var starGazingIndexCardViewModel: StarGazingIndexCardViewModel
    @StateObject private var nightWeatherCardViewModel: NightWeatherCardViewModel
    @StateObject private var upcomingGridViewModel: UpcomingNightsGridViewModel
    @ObservedObject var starMapViewModel: StarMapViewModel

    init(
        viewModel: DetailViewModel,
        starMapViewModel: StarMapViewModel,
        observationModePreference: ObservationModePreference
    ) {
        self.viewModel = viewModel
        self.starMapViewModel = starMapViewModel
        self.observationModePreference = observationModePreference
        _starGazingIndexCardViewModel = StateObject(
            wrappedValue: StarGazingIndexCardViewModel(
                lightPollutionService: viewModel.lightPollutionService
            )
        )
        _nightWeatherCardViewModel = StateObject(wrappedValue: NightWeatherCardViewModel())
        _upcomingGridViewModel = StateObject(wrappedValue: UpcomingNightsGridViewModel(detailViewModel: viewModel))
    }

    var body: some View {
        Group {
            if let summary = viewModel.nightSummary {
                detailContent(summary: summary)
            } else if viewModel.isCalculating {
                loadingContent
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // NightScope は没入型体験を重視するため、HIG 例外として
        // ウィンドウツールバー背景を一時的に非表示にしている。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            toolbarContent
        }
        .sheet(isPresented: $starMapViewModel.isStarMapOpen) {
            MacStarMapSheet(viewModel: starMapViewModel)
        }
        .onChange(of: starMapViewModel.isStarMapOpen) { _, isOpen in
            if isOpen {
                starMapViewModel.activatePresentationIfNeeded()
                starMapViewModel.syncWithSelectedDate()
            }
        }
        .overlay(alignment: .bottom) {
            DetailErrorOverlay(
                weatherErrorMessage: viewModel.weatherErrorMessage,
                hasLightPollutionError: viewModel.hasLightPollutionError,
                retryWeatherAction: viewModel.retryWeatherInBackground,
                retryLightPollutionAction: viewModel.retryLightPollutionInBackground
            )
        }
        .animation(reduceMotion ? .none : .standard, value: viewModel.hasWeatherError)
        .animation(reduceMotion ? .none : .standard, value: viewModel.hasLightPollutionError)
    }

    private func detailContent(summary: NightSummary) -> some View {
        let weather = viewModel.currentWeather
        return skyBackdrop {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    heroBand(summary: summary, weather: weather)
                    summarySection(
                        summary: summary,
                        weather: weather,
                        isWeatherLoading: viewModel.isWeatherLoading
                    )
                    UpcomingNightsGrid(viewModel: upcomingGridViewModel)
                    MeteorShowerCalendarView(selectedDate: viewModel.selectedDate)
                    PlanetVisibilityView(
                        selectedDate: viewModel.selectedDate,
                        location: summary.location,
                        timeZone: viewModel.selectedTimeZone
                    )
                }
                .padding(Spacing.md)
            }
        }
    }

    private var loadingContent: some View {
        let weather = viewModel.currentWeather
        return skyBackdrop {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    heroBand(summary: .placeholder, weather: weather)
                    summarySection(
                        summary: .placeholder,
                        weather: weather,
                        isWeatherLoading: viewModel.isWeatherLoading
                    )
                }
                .padding(Spacing.md)
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel(L10n.tr("星空データを計算中"))
    }

    private var emptyContent: some View {
        ContentUnavailableView(
            "データがありません",
            systemImage: AppIcons.Astronomy.moonStars,
            description: Text("場所と日付を選択してください")
        )
    }

    /// スクロール内容の背後に夜空のグラデーションを敷く。
    /// ツールバー背景を隠しているため、上端の安全領域まで伸ばして地続きに見せる。
    private func skyBackdrop<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            SkyGradientBackground(height: HeroLayout.backgroundHeight)
                .backgroundExtensionEffectCompat()
                .ignoresSafeArea(.container, edges: .top)
            content()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            locationTitleBar
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            starMapButton
            ObservationModeMenu(observationModePreference: observationModePreference)
        }
    }

    private var starMapButton: some View {
        Button {
            starMapViewModel.isStarMapOpen = true
        } label: {
            Label("星空マップ", systemImage: AppIcons.Astronomy.sparkles)
        }
        .glassButtonStyle()
        .disabled(viewModel.isCalculating)
        .help(L10n.tr("星空マップを表示"))
        .accessibilityHint(L10n.tr("選択した日付の星空マップを開きます"))
    }

    // MARK: - Location Title Bar

    private var locationTitleBar: some View {
        HStack(alignment: .lastTextBaseline, spacing: Spacing.sm) {
            Text(viewModel.locationName)
                .font(.headline)
                .lineLimit(1)
            Text(
                DateFormatters.yearMonthDayWeekdayString(
                    from: viewModel.displayedDate,
                    timeZone: viewModel.selectedTimeZone
                )
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if viewModel.isCalculating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.tr("右側の情報を更新中"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Hero Band

    /// 星空指数の結論（左）と夜のタイムライン（右）を空の上に並べる。
    /// 900pt 未満では 2 列に収まらないため、縦積みへ切り替える。
    private func heroBand(summary: NightSummary, weather: DayWeatherSummary?) -> some View {
        let index = viewModel.displayedStarGazingIndex
        let verdict = NightVerdictPresentation(
            index: index,
            summary: summary,
            weather: weather,
            hasReliableWeather: weather != nil && !viewModel.isCurrentWeatherCoverageIncomplete
        )
        let timeline = NightTimelineModel(
            summary: summary,
            nighttimeHours: weather?.nighttimeHours ?? []
        )
        let hero = TonightHeroView(
            index: index,
            verdict: verdict,
            isCalculating: viewModel.isCalculating
        )
        let timelineView = NightTimelineView(model: timeline, style: .onSky)

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Spacing.lg) {
                hero
                    .frame(
                        minWidth: HeroLayout.heroMinWidth,
                        maxWidth: HeroLayout.heroMaxWidth,
                        alignment: .leading
                    )
                timelineView
                    .frame(minWidth: HeroLayout.timelineMinWidth)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                hero
                    .frame(maxWidth: HeroLayout.heroMaxWidth, alignment: .leading)
                timelineView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary

    /// 要約カード 4 枚と星空指数の内訳を、空の下のコンテンツ層へまとめる。
    private func summarySection(
        summary: NightSummary,
        weather: DayWeatherSummary?,
        isWeatherLoading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            GlassEffectContainerCompat {
                ViewThatFits(in: .horizontal) {
                    MacSummaryCardsWide(
                        summary: summary,
                        weather: weather,
                        isWeatherLoading: isWeatherLoading,
                        isForecastOutOfRange: viewModel.isCurrentWeatherForecastOutOfRange,
                        isCoverageIncomplete: viewModel.isCurrentWeatherCoverageIncomplete,
                        weatherViewModel: nightWeatherCardViewModel
                    )
                    MacSummaryCardsWrapped(
                        summary: summary,
                        weather: weather,
                        isWeatherLoading: isWeatherLoading,
                        isForecastOutOfRange: viewModel.isCurrentWeatherForecastOutOfRange,
                        isCoverageIncomplete: viewModel.isCurrentWeatherCoverageIncomplete,
                        weatherViewModel: nightWeatherCardViewModel
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let index = viewModel.displayedStarGazingIndex {
                IndexBreakdownView(
                    index: index,
                    lightPollutionViewModel: starGazingIndexCardViewModel,
                    layout: .row
                )
                .padding(Layout.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }

            // 帰属表示は直下の 9 日予報見出し行に集約する（同一画面で 2 つ並ぶのを避ける）。
        }
    }

}

private enum HeroLayout {
    /// 空のグラデーションの高さ。ツールバー領域とヒーロー帯をちょうど覆う。
    static let backgroundHeight: CGFloat = 300
    /// 2 列レイアウトを維持するために必要な左カラムの最小幅。
    static let heroMinWidth: CGFloat = 400
    /// 左カラムの最大幅。これ以上広げると数値と見出しが離れすぎる。
    static let heroMaxWidth: CGFloat = 440
    /// 2 列レイアウトを維持するために必要な右カラムの最小幅。
    static let timelineMinWidth: CGFloat = 468
}

private enum MacSummaryCardLayout {
    static let minimumWidth: CGFloat = LayoutMacOS.summaryCardMinWidth
}

private struct MacSummaryCardsWide: View {
    let summary: NightSummary
    let weather: DayWeatherSummary?
    let isWeatherLoading: Bool
    let isForecastOutOfRange: Bool
    let isCoverageIncomplete: Bool
    @ObservedObject var weatherViewModel: NightWeatherCardViewModel

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: MacSummaryCardLayout.minimumWidth), spacing: Spacing.xs),
                GridItem(.flexible(minimum: MacSummaryCardLayout.minimumWidth), spacing: Spacing.xs),
                GridItem(.flexible(minimum: MacSummaryCardLayout.minimumWidth), spacing: Spacing.xs),
                GridItem(.flexible(minimum: MacSummaryCardLayout.minimumWidth), spacing: Spacing.xs)
            ],
            alignment: .leading,
            spacing: Spacing.xs
        ) {
            DarkTimeCard(summary: summary, weather: weather, style: .compact)
            NightWeatherCard(
                weather: weather,
                isLoading: isWeatherLoading,
                isForecastOutOfRange: isForecastOutOfRange,
                isCoverageIncomplete: isCoverageIncomplete,
                errorMessage: nil,
                viewModel: weatherViewModel,
                style: .compact
            )
            MoonPhaseCard(summary: summary, style: .compact)
            MilkyWaySummaryCard(summary: summary, style: .compact)
        }
    }
}

private struct MacSummaryCardsWrapped: View {
    let summary: NightSummary
    let weather: DayWeatherSummary?
    let isWeatherLoading: Bool
    let isForecastOutOfRange: Bool
    let isCoverageIncomplete: Bool
    @ObservedObject var weatherViewModel: NightWeatherCardViewModel

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: MacSummaryCardLayout.minimumWidth), spacing: Spacing.xs)
            ],
            alignment: .leading,
            spacing: Spacing.xs
        ) {
            DarkTimeCard(summary: summary, weather: weather, style: .compact)
            NightWeatherCard(
                weather: weather,
                isLoading: isWeatherLoading,
                isForecastOutOfRange: isForecastOutOfRange,
                isCoverageIncomplete: isCoverageIncomplete,
                errorMessage: nil,
                viewModel: weatherViewModel,
                style: .compact
            )
            MoonPhaseCard(summary: summary, style: .compact)
            MilkyWaySummaryCard(summary: summary, style: .compact)
        }
    }
}

private struct MacStarMapSheet: View {
    @ObservedObject var viewModel: StarMapViewModel

    @State private var selectedStar: StarPosition?

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            StarMapCanvasView(viewModel: viewModel) { star in
                selectedStar = star
            }
            .frame(minWidth: StarMapLayout.canvasMinWidth, minHeight: StarMapLayout.canvasMinHeight)
            .popover(item: $selectedStar) { star in
                StarInfoMacView(starPosition: star)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: StarMapLayout.sheetMinWidth, minHeight: StarMapLayout.sheetMinHeight)
        .onDisappear {
            selectedStar = nil
        }
    }

    private var headerSection: some View {
        HStack {
            Text("星空マップ")
                .font(.title3)
                .fontWeight(.semibold)

            Spacer()

            Button(action: closeSheet) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("星空マップを閉じる"))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.sm)
    }

    /// ステータスと操作を 1 本にまとめたシート下部のバー。
    private var bottomBar: some View {
        VStack(spacing: Spacing.xs) {
            controlRow
            timelineRow
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
    }

    /// 時刻・日付・ステータス・操作ボタンを 1 行に並べる。
    private var controlRow: some View {
        HStack(spacing: Spacing.xs) {
            Text(viewModel.displayTimeString)
                .font(.title2.weight(.semibold))
                .monospacedDigit()

            DatePicker("", selection: observationDateBinding, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
                .fixedSize()

            Spacer()

            statusChips

            Button {
                viewModel.resetToNow()
            } label: {
                Text("現在")
                    .font(.caption.weight(.semibold))
            }
            .glassButtonStyle()
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .frame(height: StarMapLayout.macControlRowHeight)

            Button(action: viewModel.resetToNorth) {
                Text("北を向く")
                    .font(.caption.weight(.semibold))
            }
            .glassButtonStyle()
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .frame(height: StarMapLayout.macControlRowHeight)
            .help(L10n.tr("北を向き、地平線を下端付近に合わせてリセット  [N]"))
        }
        .frame(minHeight: StarMapLayout.macControlRowHeight)
    }

    /// 方位・仰角・視野・地形・月・流星群を 1 行のチップ列にまとめる。
    private var statusChips: some View {
        HStack(spacing: StarMapLayout.macStatusChipSpacing) {
            statusChip(
                systemImage: "location.north.circle",
                text: StarMapPresentation.azimuthName(for: viewModel.viewAzimuth)
                    + " " + AngleMath.degreesText(viewModel.viewAzimuth, fractionDigits: 0),
                tint: .secondary
            )

            statusChip(
                systemImage: "arrow.up.circle",
                text: L10n.format("仰角 %.0f°", viewModel.viewAltitude),
                tint: .secondary
            )

            statusChip(
                systemImage: "viewfinder",
                text: L10n.format("視野 %.0f°", viewModel.fov),
                tint: .secondary
            )

            statusChip(
                systemImage: viewModel.terrainFetchState.systemImageName,
                text: viewModel.terrainFetchState.statusText,
                tint: terrainStatusColor
            )
            .accessibilityLabel(L10n.format("地形データ状態: %@", viewModel.terrainFetchState.statusText))

            if viewModel.moonAltitude > 0 {
                statusChip(
                    systemImage: "moon.fill",
                    text: L10n.format("月 %.0f°", viewModel.moonAltitude),
                    tint: .white.opacity(0.8)
                )
            }

            if let meteorStatus {
                statusChip(
                    systemImage: AppIcons.Astronomy.sparkles,
                    text: meteorStatus.text,
                    tint: meteorStatus.tint
                )
            }
        }
        .lineLimit(1)
        .layoutPriority(-1)
    }

    private func statusChip(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }

    /// 活動中の流星群を優先し、無ければ次の流星群を返す。
    private var meteorStatus: (text: String, tint: Color)? {
        if let radiant = viewModel.meteorShowerRadiants.first {
            return (
                L10n.format("%@活動中", radiant.shower.localizedName),
                StarMapPalette.meteorAccent
            )
        }
        if let next = viewModel.nextMeteorShower {
            return (
                L10n.format("%@ %d日後", next.shower.localizedName, next.daysUntilPeak),
                .secondary
            )
        }
        return nil
    }

    private var terrainStatusColor: Color {
        switch viewModel.terrainFetchState {
        case .idle, .loading:
            .secondary
        case .available:
            StarMapPalette.terrainAvailable
        case .unavailable:
            .orange
        }
    }

    /// ヒートバーと時刻スライダーを重ねた時間軸行。
    private var timelineRow: some View {
        // macOS の Slider つまみは iOS より大きいため、iOS より広めの間隔を取る。
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ObservationHeatBarView(
                observationConditionTimeline: viewModel.observationConditionTimeline,
                sliderFraction: viewModel.timeSliderFraction,
                currentMoonAltitude: viewModel.moonAltitude,
                currentMoonPhase: viewModel.moonPhase,
                currentSunAltitude: viewModel.sunAltitude,
                currentTimeText: viewModel.displayTimeString
            )
            // Slider のつまみ半径ぶん内側に寄せ、スライダーのトラック端と揃える。
            .padding(.horizontal, StarMapLayout.macHeatBarTrackInset)

            Slider(
                value: timeSliderBinding,
                in: 0...viewModel.timeSliderMaximumMinutes,
                step: 1,
                onEditingChanged: timeSliderEditingChanged
            )
            .labelsHidden()
            .accessibilityLabel(L10n.tr("時刻"))
            .accessibilityValue(viewModel.displayTimeString)
        }
    }

    private func closeSheet() {
        viewModel.isStarMapOpen = false
    }

    private var timeSliderBinding: Binding<Double> {
        Binding(
            get: { viewModel.timeSliderMinutes },
            set: { viewModel.setTimeSliderMinutes($0) }
        )
    }

    private var observationDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.observationDate },
            set: { viewModel.setObservationDate($0) }
        )
    }

    private func timeSliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            viewModel.beginTimeSliderInteraction()
        } else {
            viewModel.endTimeSliderInteraction()
        }
    }
}
