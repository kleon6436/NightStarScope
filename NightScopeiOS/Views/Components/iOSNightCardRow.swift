import SwiftUI

/// 9日予報の 1 行分を表示するカード。
/// 日付・雲量・星空指数・薄明開始を固定幅の列に並べ、行をまたいで数値が縦に揃うようにする。
struct iOSNightCardRow: View {
    let night: NightSummary
    let index: StarGazingIndex?
    let weather: DayWeatherSummary?
    let isReliableWeather: Bool
    let hasPartialWeather: Bool
    let isForecastOutOfRange: Bool
    let hasWeatherLoadError: Bool
    let isSelected: Bool
    /// true のとき時間別の雲量ストリップを行の下に開く。
    var showsHourlyStrip: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// アクセシビリティ文字サイズでは固定幅の 4 列が収まらないため、2 段組みに切り替える。
    private var usesStackedLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var presentation: ForecastCardPresentation {
        ForecastCardPresentation(
            night: night,
            weather: weather,
            timeZone: night.timeZone,
            isReliableWeather: isReliableWeather,
            hasPartialWeather: hasPartialWeather,
            isForecastOutOfRange: isForecastOutOfRange,
            hasWeatherLoadError: hasWeatherLoadError
        )
    }

    private var stripHours: [HourlyWeather]? {
        guard showsHourlyStrip, let hours = weather?.nighttimeHours, !hours.isEmpty else { return nil }
        return hours
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IOSDesignTokens.NightRow.contentSpacing) {
            mainRow
            if let hours = stripHours {
                hourlyStrip(hours)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IOSDesignTokens.NightRow.cardHorizontalPadding)
        .padding(.vertical, IOSDesignTokens.NightRow.cardVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: IOSDesignTokens.NightRow.cardMinHeight,
            alignment: .center
        )
        // 選択色はカード面より上・本文より下に重なるよう、cardSurface より内側で敷く。
        .background(
            cardShape.fill(
                Color.accentColor.opacity(isSelected ? IOSDesignTokens.NightRow.selectionTintOpacity : 0)
            )
        )
        .cardSurface()
        .overlay(
            cardShape.stroke(
                isSelected ? Color.accentColor : Color.clear,
                lineWidth: IOSDesignTokens.NightRow.selectionBorderWidth
            )
        )
        .animation(reduceMotion ? nil : .standard, value: showsHourlyStrip)
    }

    // MARK: - Main Row

    @ViewBuilder
    private var mainRow: some View {
        if usesStackedLayout {
            VStack(alignment: .leading, spacing: IOSDesignTokens.NightRow.contentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    dateColumn
                    Spacer(minLength: Spacing.xs)
                    trailingColumn
                }
                HStack(alignment: .center, spacing: Spacing.sm) {
                    cloudColumn
                    indexColumn
                }
            }
        } else {
            HStack(alignment: .center, spacing: Spacing.xs) {
                dateColumn
                cloudColumn
                indexColumn
                trailingColumn
            }
        }
    }

    private var dateColumn: some View {
        VStack(alignment: .leading, spacing: IOSDesignTokens.NightRow.tightLineSpacing) {
            Text(presentation.shortDateLabel)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            if let label = presentation.relativeNightLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: usesStackedLayout ? nil : IOSDesignTokens.NightRow.dateColumnWidth, alignment: .leading)
    }

    private var cloudColumn: some View {
        HStack(spacing: IOSDesignTokens.NightRow.metadataIconSpacing) {
            Image(systemName: AppIcons.Weather.cloud)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(presentation.cloudCoverText)
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(IOSDesignTokens.NightRow.metadataMinimumScaleFactor)
        }
        .frame(width: usesStackedLayout ? nil : IOSDesignTokens.NightRow.cloudColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private var indexColumn: some View {
        HStack(spacing: IOSDesignTokens.NightRow.contentSpacing) {
            if let index {
                tierSquares(for: index)
                Text(index.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(index.tier.color)
                    .lineLimit(1)
                    .minimumScaleFactor(IOSDesignTokens.NightRow.metadataMinimumScaleFactor)
            } else {
                Text(Placeholder.dash)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tierSquares(for index: StarGazingIndex) -> some View {
        HStack(spacing: IOSDesignTokens.NightRow.tierSquareSpacing) {
            ForEach(0..<IOSDesignTokens.NightRow.tierSquareCount, id: \.self) { position in
                RoundedRectangle(
                    cornerRadius: IOSDesignTokens.NightRow.tierSquareCornerRadius,
                    style: .continuous
                )
                .fill(
                    position < index.starCount
                    ? AnyShapeStyle(index.tier.color)
                    : AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                )
                .frame(
                    width: IOSDesignTokens.NightRow.tierSquareSize,
                    height: IOSDesignTokens.NightRow.tierSquareSize
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: IOSDesignTokens.NightRow.tightLineSpacing) {
            Text(presentation.darkStartText ?? Placeholder.dash)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detailText = presentation.weatherDetailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(IOSDesignTokens.NightRow.metadataMinimumScaleFactor)
            }
        }
        .frame(width: usesStackedLayout ? nil : IOSDesignTokens.NightRow.trailingColumnWidth, alignment: .trailing)
    }

    // MARK: - Hourly Strip

    /// 選択中の夜だけ、1 時間ごとの雲量を帯で示す。
    /// 濃さ＝雲量、青み＝降水ありとし、両端に時刻を添えて帯の範囲を読めるようにする。
    private func hourlyStrip(_ hours: [HourlyWeather]) -> some View {
        VStack(alignment: .leading, spacing: IOSDesignTokens.NightRow.tightLineSpacing) {
            HStack(spacing: 0) {
                ForEach(hours.indices, id: \.self) { position in
                    Rectangle()
                        .fill(hourColor(hours[position]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: IOSDesignTokens.NightRow.hourlyStripHeight)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: IOSDesignTokens.NightRow.hourlyStripCornerRadius,
                    style: .continuous
                )
            )

            if let first = hours.first, let last = hours.last {
                HStack(spacing: 0) {
                    Text(first.date.nightTimeString(timeZone: night.timeZone))
                    Spacer(minLength: 0)
                    Text(last.date.nightTimeString(timeZone: night.timeZone))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func hourColor(_ hour: HourlyWeather) -> Color {
        let base: Color = hour.precipitationMM > 0 ? .blue : .secondary
        return base.opacity(min(max(hour.cloudCoverPercent / 100, 0), 1))
    }
}
