import SwiftUI

/// 夜間の天気概況をまとめたカード。
struct NightWeatherCard: View {
    let weather: DayWeatherSummary?
    let isLoading: Bool
    let isForecastOutOfRange: Bool
    let isCoverageIncomplete: Bool
    let errorMessage: String?
    @ObservedObject var viewModel: NightWeatherCardViewModel
    var style: SummaryCardStyle = .regular

    var body: some View {
        switch style {
        case .regular: regularBody
        case .compact: compactBody
        }
    }

    // MARK: - Compact

    private var compactBody: some View {
        MetricCard(icon: AppIcons.Weather.cloud, title: "天気 (夜間)", tint: .cyan) {
            weatherTextContent
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Regular

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            CardHeader(icon: AppIcons.Weather.cloud, iconColor: .cyan, title: "天気 (夜間)")
            HStack(alignment: .center, spacing: Spacing.sm) {
                weatherVisual
                weatherTextContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: CardVisual.metricVisualHeight, alignment: .leading)
        }
        .contentCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        viewModel.accessibilityDescription(
            weather: weather,
            isLoading: isLoading,
            isForecastOutOfRange: isForecastOutOfRange,
            isCoverageIncomplete: isCoverageIncomplete,
            errorMessage: errorMessage
        )
    }

    /// `.compact` では同じ文面をひと回り小さい字で出す。行構成は変えない。
    private var titleFont: Font {
        style == .compact ? .title3.weight(.semibold) : .headline
    }

    private var detailFont: Font {
        style == .compact ? .footnote : .body
    }

    @ViewBuilder
    private var weatherVisual: some View {
        WeatherSymbolVisual(weather: weather, isLoading: isLoading)
            .frame(width: CardVisual.width, height: CardVisual.arcHeight)
            .summaryCardMetricVisualFrame()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var weatherTextContent: some View {
        VStack(alignment: .leading, spacing: style == .compact ? Spacing.xs / 2 : Spacing.xs) {
            if let weather, !isCoverageIncomplete {
                Text(viewModel.weatherLabel(weather))
                    .font(titleFont)
                    .lineLimit(1)
                Text(viewModel.formatMetrics(precipitation: weather.maxPrecipitation, cloudCover: weather.avgCloudCover))
                    .font(detailFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.formatWindSpeed(weather.avgWindSpeed))
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if viewModel.showDewRiskWarning(weather) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: viewModel.dewRiskIconName(weather))
                            .foregroundStyle(viewModel.dewRiskColor(weather))
                        Text(viewModel.dewRiskLabel(weather))
                            .foregroundStyle(viewModel.dewRiskColor(weather))
                    }
                    .font(detailFont)
                    .lineLimit(1)
                }
            } else if isCoverageIncomplete {
                Text(viewModel.partialCoverageTitle())
                    .font(titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.partialCoveragePrimaryText())
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.partialCoverageSecondaryText())
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if isLoading {
                Text(L10n.tr("取得中..."))
                    .font(titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("最新データを取得しています")
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("しばらくお待ちください")
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let errorMessage {
                Text(viewModel.errorTitle())
                    .font(titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.errorPrimaryText(errorMessage))
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.errorSecondaryText())
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(viewModel.unavailableTitle(isForecastOutOfRange: isForecastOutOfRange))
                    .font(titleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.unavailablePrimaryText(isForecastOutOfRange: isForecastOutOfRange))
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(viewModel.unavailableSecondaryText(isForecastOutOfRange: isForecastOutOfRange))
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Weather Symbol Visual

/// 天気アイコンまたは読み込み中インジケータを描く。
private struct WeatherSymbolVisual: View {
    let weather: DayWeatherSummary?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading && weather == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: weather?.weatherIconName ?? "questionmark.circle")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        weather.map { WeatherPresentation.color(forWeatherCode: $0.representativeWeatherCode) }
                        ?? .secondary
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WeatherAttributionBadge

/// WeatherKit 利用規約に基づく帰属表示バッジ。
/// Apple の天気データを表示する画面には Apple Weather 商標と、他データソースへの法的リンクが必須。
/// - compact: 天気を表示するセクションの末尾に置く小さなマーク（タップで法的情報ページへ）
/// - full: 設定「データソースとクレジット」用（マーク + リンク文言）
struct WeatherAttributionBadge: View {
    enum Style { case compact, full }
    /// マークの高さ。画像はロゴ込みで文字より背が高いため、隣接する文字の cap height に合わせて小さめに取る。
    enum Size { case caption, headline }
    /// `WeatherAttribution.legalPageURL` が取得できない場合の予備リンク。
    private static let legalURL = URL(string: "https://developer.apple.com/weatherkit/data-source-attribution/")!

    var style: Style = .compact
    var size: Size = .caption

    @EnvironmentObject private var attributionService: WeatherAttributionService
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var captionMarkHeight = AttributionMetrics.captionMarkHeight
    @ScaledMetric(relativeTo: .title3) private var headlineMarkHeight = AttributionMetrics.headlineMarkHeight

    private var markHeight: CGFloat {
        size == .headline ? headlineMarkHeight : captionMarkHeight
    }

    var body: some View {
        Group {
            if let data = attributionService.attributionData {
                switch style {
                case .compact:
                    Link(destination: data.legalPageURL) {
                        HStack(spacing: AttributionMetrics.chevronSpacing) {
                            combinedMark(url: markURL(for: data), height: markHeight)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                case .full:
                    VStack(alignment: .leading, spacing: AttributionMetrics.fullSpacing) {
                        combinedMark(url: markURL(for: data), height: AttributionMetrics.fullMarkHeight)
                        Link(L10n.tr("法的情報・著作権"), destination: data.legalPageURL)
                            .font(.caption2)
                    }
                }
            } else {
                fallbackAttribution
            }
        }
        .accessibilityLabel(L10n.tr("天気データ提供: Apple Weather。データソースの法的情報を開く"))
        .task { await attributionService.loadIfNeeded() }
    }

    /// マークはカラースキームに追従して明暗を切り替える。
    private func markURL(for data: WeatherAttributionData) -> URL {
        colorScheme == .dark ? data.logoDarkURL : data.logoLightURL
    }

    @ViewBuilder
    private var fallbackAttribution: some View {
        switch style {
        case .compact:
            Link(destination: Self.legalURL) {
                HStack(spacing: AttributionMetrics.chevronSpacing) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Apple Weather"))
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        case .full:
            VStack(alignment: .leading, spacing: AttributionMetrics.fullSpacing) {
                HStack(spacing: AttributionMetrics.chevronSpacing) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Apple Weather"))
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Link(L10n.tr("Weather data sources"), destination: Self.legalURL)
                    .font(.caption2)
            }
        }
    }

    private func combinedMark(url: URL, height: CGFloat) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Text(L10n.tr("Apple Weather"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: height)
    }

    private enum AttributionMetrics {
        /// Apple 提供のマーク画像はそのまま使う。caption（13pt）と並ぶときは cap height 相当の 10pt、
        /// title3 Bold（15pt）の見出し行に並ぶときは 12pt で、隣の文字と同じ高さに見せる。
        static let captionMarkHeight: CGFloat = 10
        static let headlineMarkHeight: CGFloat = 12
        static let fullMarkHeight: CGFloat = 18
        static let chevronSpacing: CGFloat = 4
        static let fullSpacing: CGFloat = 4
    }
}
