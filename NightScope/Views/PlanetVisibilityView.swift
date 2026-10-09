import SwiftUI
import CoreLocation
#if os(iOS)
import Charts
#endif

// MARK: - PlanetVisibilityView

/// 今夜の惑星可視情報セクション（macOS / iOS 共通）。
struct PlanetVisibilityView: View {
    let selectedDate: Date
    let location: CLLocationCoordinate2D
    let timeZone: TimeZone

    var body: some View {
        PlanetVisibilityContent(selectedDate: selectedDate, location: location, timeZone: timeZone)
            // 出・南中・没の時刻を横に並べる表のため、これ以上大きくすると 2 段組みでも収まらない。
            // 内側の @ScaledMetric にも上限を効かせるため、中身全体の外側で指定する。
            .dynamicTypeSize(...PlanetStyle.maximumTypeSize)
    }
}

private struct PlanetVisibilityContent: View {
    let selectedDate: Date
    let location: CLLocationCoordinate2D
    let timeZone: TimeZone

    @State private var summaries: [PlanetNightSummary] = []
    @State private var isLoading = true
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = PlanetStyle.rowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader
            if isLoading {
                loadingCard
            } else {
                planetsCard
            }
        }
        .task(id: taskID) {
            isLoading = true
            // Sendable 境界を越えるため値をローカルにコピー
            let capturedDate     = selectedDate
            let capturedLocation = location
            let capturedTimeZone = timeZone
            let result = await Task.detached(priority: .userInitiated) {
                MilkyWayCalculator.planetNightSummaries(
                    date: capturedDate,
                    location: capturedLocation,
                    timeZone: capturedTimeZone
                )
            }.value
            // .task(id:) の取り消しは detached タスクへ伝わらないため、
            // 入力が変わった後に古い結果で上書きしないよう確認する。
            // 取り消された場合は次の実行が isLoading を管理する。
            guard !Task.isCancelled else { return }
            summaries = result
            isLoading = false
        }
    }

    // MARK: - Private Subviews

    private var sectionHeader: some View {
        // 見出しと日付が 1 行に並ばない文字サイズでは、日付を見出しの下へ回す。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle
                Spacer()
                sectionCaption
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                sectionTitle
                sectionCaption
            }
        }
    }

    private var sectionTitle: some View {
        Text(L10n.tr("今夜の惑星"))
            .font(.title3.bold())
    }

    private var sectionCaption: some View {
        Text(nightDateLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var planetsCard: some View {
        VStack(spacing: 0) {
            ForEach(summaries) { summary in
                PlanetRow(summary: summary, timeZone: timeZone)
                    .frame(minHeight: rowHeight)
                if summary.id != summaries.last?.id {
                    Divider()
                        .opacity(0.4)
                        .padding(.horizontal, Spacing.xs)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .opaqueCardBackground(in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
    }

    private var loadingCard: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: rowHeight * 5 + Spacing.xs * 2)
        .opaqueCardBackground(in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
    }

    // MARK: - Helpers

    /// 再計算を起動するキー。日付・緯度・経度・タイムゾーンが変わったら変化する。
    private var taskID: String {
        "\(selectedDate.timeIntervalSinceReferenceDate)-\(location.latitude)-\(location.longitude)-\(timeZone.identifier)"
    }

    private var nightDateLabel: String {
        DateFormatters.monthDayString(from: selectedDate, timeZone: timeZone)
    }
}

// MARK: - PlanetRow

private struct PlanetRow: View {
    let summary: PlanetNightSummary
    let timeZone: TimeZone

    @State private var isHovered = false
    @ScaledMetric(relativeTo: .callout) private var nameWidth: CGFloat = PlanetStyle.nameWidth
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = PlanetStyle.timeWidth
    @ScaledMetric(relativeTo: .subheadline) private var altWidth: CGFloat = PlanetStyle.altWidth
    @ScaledMetric(relativeTo: .callout) private var difficultyIconSize: CGFloat = PlanetStyle.difficultyIconSize

    var body: some View {
        // 1 行に収まらない文字サイズでは、名前と高度の行・時刻の行の 2 段に分ける。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                nameLabel
                Spacer()
                timeEntries
                altitudeText
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    nameLabel
                    Spacer()
                    altitudeText
                }
                HStack(spacing: Spacing.xs) {
                    Spacer()
                    timeEntries
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
        .padding(.horizontal, Spacing.xs)
        .opacity(summary.isVisibleTonight ? 1 : 0.4)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .hoverTooltipOrTapSheet(isHovered: $isHovered) {
            hoverTooltip
        } sheet: {
            PlanetDetailSheet(summary: summary, timeZone: timeZone)
        }
        .zIndex(isHovered ? 10 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: Components

    private var nameLabel: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: summary.observationDifficulty.systemImage)
                .font(.system(size: difficultyIconSize))
                .foregroundStyle(summary.observationDifficulty.color)
            Text(summary.localizedName)
                .font(.callout)
                .frame(width: nameWidth, alignment: .leading)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var timeEntries: some View {
        timeEntry(symbol: "↑", date: summary.riseTime)
        timeEntry(symbol: "▲", date: summary.transitTime)
        timeEntry(symbol: "↓", date: summary.setTime)
    }

    private var altitudeText: some View {
        Text(altitudeLabel)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: altWidth, alignment: .trailing)
    }

    private func timeEntry(symbol: String, date: Date?) -> some View {
        HStack(spacing: 2) {
            Text(symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(date.map { $0.nightTimeString(timeZone: timeZone) } ?? Placeholder.dash)
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(width: timeWidth, alignment: .leading)
    }

    // MARK: Hover Tooltip (macOS)

    private var hoverTooltip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.localizedName)
                .font(.caption.bold())
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(iconColor)
                Text(L10n.format("等級 %.1f", summary.magnitude))
            }
            .font(.caption)
            HStack(spacing: 4) {
                Image(systemName: summary.observationDifficulty.systemImage)
                    .foregroundStyle(summary.observationDifficulty.color)
                Text(summary.observationDifficulty.localizedLabel)
            }
            .font(.caption)
            Text(L10n.format("最大高度 %.1f°", summary.peakAltitude))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(summary.transitAzimuthLabel())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardSurface(cornerRadius: Layout.smallCornerRadius)
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
        .offset(y: PlanetStyle.rowHeight - 4)
        .padding(.trailing, Spacing.xs)
        .fixedSize()
    }

    // MARK: Helpers

    private var iconColor: Color {
        switch summary.name {
        case "水星": return .gray
        case "金星": return .yellow
        case "火星": return .red
        case "木星": return .orange
        case "土星": return .blue
        default:     return .primary
        }
    }

    private var altitudeLabel: String {
        DisplayFormat.degrees(summary.peakAltitude)
    }

    private var accessibilityDescription: String {
        let rise    = summary.riseTime?.nightTimeString(timeZone: timeZone)    ?? Placeholder.dash
        let transit = summary.transitTime?.nightTimeString(timeZone: timeZone) ?? Placeholder.dash
        let set     = summary.setTime?.nightTimeString(timeZone: timeZone)     ?? Placeholder.dash
        let alt     = String(format: "%.1f", summary.peakAltitude)
        return L10n.format("%@、出 %@、南中 %@、没 %@、最大高度 %@度",
                           summary.localizedName, rise, transit, set, alt)
    }
}

// MARK: - PlanetDetailSheet (iOS)

private struct PlanetDetailSheet: View {
    let summary: PlanetNightSummary
    let timeZone: TimeZone

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                Text(summary.localizedName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 12) {
                    infoRow(
                        label: "出",
                        value: summary.riseTime?.nightTimeString(timeZone: timeZone) ?? Placeholder.dash
                    )
                    infoRow(label: "出 方位", value: summary.riseAzimuthLabel())
                    infoRow(
                        label: "南中",
                        value: summary.transitTime?.nightTimeString(timeZone: timeZone) ?? Placeholder.dash
                    )
                    infoRow(label: "南中 方位", value: summary.transitAzimuthLabel())
                    infoRow(
                        label: "没",
                        value: summary.setTime?.nightTimeString(timeZone: timeZone) ?? Placeholder.dash
                    )
                    infoRow(label: "没 方位", value: summary.setAzimuthLabel())
                    infoRow(label: "最大高度", value: DisplayFormat.degrees(summary.peakAltitude))
                    infoRow(label: "等級",    value: String(format: "%.1f",   summary.magnitude))
                    infoRow(label: "観測難易度", value: summary.observationDifficulty.localizedLabel)
                }

#if os(iOS)
                altitudeChart
#endif
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
    }

#if os(iOS)
    private var altitudeChart: some View {
        Chart {
            ForEach(summary.altitudeSamples, id: \.time) { sample in
                LineMark(
                    x: .value(L10n.tr("時刻"), sample.time),
                    y: .value(L10n.tr("高度"), sample.altitude)
                )
            }
            RuleMark(y: .value(L10n.tr("地平線"), 0.0))
                .foregroundStyle(.secondary)
            RuleMark(y: .value(L10n.tr("観測閾値"), 10.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                .foregroundStyle(.orange)
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
            }
        }
        // 観測地タイムゾーンを適用して、rise/transit/set 時刻と一致させる
        .environment(\.timeZone, timeZone)
        .frame(height: 140)
        .padding(.top, 8)
    }
#endif

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(L10n.tr(label))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

extension ObservationDifficulty {
    var color: Color {
        switch self {
        case .nakedEye: return .green
        case .binoculars: return .yellow
        case .telescope: return .orange
        }
    }
}

// MARK: - PlanetStyle

private enum PlanetStyle {
    static let rowHeight: CGFloat = 36
    static let nameWidth: CGFloat = 52
    static let timeWidth: CGFloat = 60
    static let altWidth:  CGFloat = 52
    static let difficultyIconSize: CGFloat = 11
    /// 2 段組みでも出・南中・没の時刻が 1 行に収まる上限の文字サイズ。
    static let maximumTypeSize: DynamicTypeSize = .accessibility2
}

// MARK: - Preview

#Preview {
    ScrollView {
        PlanetVisibilityView(
            selectedDate: Date(),
            location: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        .padding()
    }
    .frame(width: 600, height: 300)
}
