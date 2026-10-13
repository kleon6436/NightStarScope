import SwiftUI

// MARK: - MoonlightLevel (View 層の表示)

extension MoonPhase.MoonlightLevel {
    var label: String {
        switch self {
        case .low: return L10n.tr("月明かりほぼなし")
        case .moderate: return L10n.tr("月明かりやや明るい")
        case .high: return L10n.tr("月明かり強い")
        }
    }

    var icon: String {
        switch self {
        case .low: return AppIcons.Astronomy.moonlightLow
        case .moderate: return AppIcons.Astronomy.moonlightModerate
        case .high: return AppIcons.Astronomy.moonlightHigh
        }
    }

    var tint: Color {
        switch self {
        case .low: return .indigo
        case .moderate: return .secondary
        case .high: return .orange
        }
    }
}

// MARK: - LunarCalendarView

/// 1 か月分の月相をグリッドで表示する月齢カレンダー（macOS / iOS 共通）。
struct LunarCalendarView: View {
    @ObservedObject var viewModel: LunarCalendarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LunarCalendarHeader(viewModel: viewModel)
            LunarPhaseEventList(events: viewModel.phaseEvents, timeZone: viewModel.timeZone)
            LunarCalendarGrid(viewModel: viewModel)
            LunarCalendarLegend()
        }
        .dynamicTypeSize(...LunarCalendarStyle.maximumTypeSize)
    }
}

// MARK: - Header

private struct LunarCalendarHeader: View {
    @ObservedObject var viewModel: LunarCalendarViewModel

    var body: some View {
        HStack {
            Button { viewModel.shiftMonth(by: -1) } label: {
                Image(systemName: AppIcons.Controls.chevronLeft)
                    .font(.body.bold())
                    .frame(width: LunarCalendarStyle.navigationButtonSize, height: LunarCalendarStyle.navigationButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!viewModel.canShiftBackward)
            .accessibilityLabel(L10n.tr("前の月"))

            Spacer()

            Text(DateFormatters.monthTitleString(from: viewModel.displayMonth, timeZone: viewModel.timeZone))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button { viewModel.shiftMonth(by: 1) } label: {
                Image(systemName: AppIcons.Controls.chevronRight)
                    .font(.body.bold())
                    .frame(width: LunarCalendarStyle.navigationButtonSize, height: LunarCalendarStyle.navigationButtonSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!viewModel.canShiftForward)
            .accessibilityLabel(L10n.tr("次の月"))

            Button(action: viewModel.goToToday) {
                Text(L10n.tr("今日"))
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: LunarCalendarStyle.navigationButtonSize, minHeight: LunarCalendarStyle.navigationButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Phase Event List

/// 表示月の主要月相をアイコンと実際の日時で並べる。
struct LunarPhaseEventList: View {
    let events: [LunarPhaseEvent]
    let timeZone: TimeZone

    private let columns = [GridItem(.adaptive(minimum: LunarCalendarStyle.eventMinimumWidth), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xs) {
            ForEach(events, id: \.date) { event in
                Label {
                    Text(L10n.format(
                        "%@ %@ %@",
                        event.kind.name,
                        DateFormatters.monthDayString(from: event.date, timeZone: timeZone),
                        DateFormatters.nightTimeString(from: event.date, timeZone: timeZone)
                    ))
                    .font(.footnote.monospacedDigit())
                } icon: {
                    Image(systemName: event.kind.icon)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }
}

// MARK: - Grid

private struct LunarCalendarGrid: View {
    @ObservedObject var viewModel: LunarCalendarViewModel

    private var weekdayLabels: [CalendarView.WeekdayHeaderItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        return CalendarView.makeWeekdayHeaderItems(from: calendar.veryShortStandaloneWeekdaySymbols)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.xxs), count: 7)

    var body: some View {
        let today = viewModel.today
        VStack(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                ForEach(weekdayLabels) { item in
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            LazyVGrid(columns: columns, spacing: Spacing.xxs) {
                ForEach(Array(viewModel.days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        LunarCalendarDayCell(
                            day: day,
                            timeZone: viewModel.timeZone,
                            isSouthernHemisphere: viewModel.isSouthernHemisphere,
                            isSelected: day.date == viewModel.selectedNight,
                            isToday: day.date == today,
                            onTap: { viewModel.select(day.date) }
                        )
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: LunarCalendarStyle.cellMinHeight)
                    }
                }
            }
        }
    }
}

// MARK: - Day Cell

/// 1 夜分のセル。日付・月の描画・月齢・主要月相・暗い夜の印を表示する。
struct LunarCalendarDayCell: View {
    let day: LunarDay
    let timeZone: TimeZone
    let isSouthernHemisphere: Bool
    let isSelected: Bool
    let isToday: Bool
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dayNumber: Int {
        ObservationTimeZone.gregorianCalendar(timeZone: timeZone).component(.day, from: day.date)
    }

    private var showsMoonAge: Bool { dynamicTypeSize <= .xxxLarge }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Text("\(dayNumber)")
                        .font(.caption.weight(isToday ? .bold : .regular))
                    if day.isDarkNight {
                        Image(systemName: AppIcons.Astronomy.darkNight)
                            .font(.caption2)
                            .imageScale(.small)
                            .foregroundStyle(Color.indigo)
                    }
                }
                MoonPhaseGlyph(phase: day.phase, isSouthernHemisphere: isSouthernHemisphere, size: LunarCalendarStyle.glyphSize)
                if showsMoonAge {
                    Text(day.moonAge.formatted(.number.precision(.fractionLength(1))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                if let event = day.principalEvent {
                    Image(systemName: event.kind.icon)
                        .font(.caption2)
                        .foregroundStyle(Color.yellow)
                }
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: LunarCalendarStyle.cellMinHeight)
            .padding(.vertical, Spacing.xxs)
            .background(background)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: Layout.smallCornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.smallCornerRadius)
        if isSelected {
            // 月の輝面が埋もれないよう、選択中も淡い塗りにとどめる。
            shape.fill(Color.accentColor.opacity(0.3))
        } else if day.isDarkNight {
            shape.fill(Color.indigo.opacity(0.18))
        } else {
            shape.fill(Color.clear)
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            L10n.format("%@の夜", DateFormatters.fullDateString(from: day.date, timeZone: timeZone)),
            day.principalEvent?.kind.name ?? MoonPhase.name(phase: day.phase),
            L10n.format("月齢 %.1f日", day.moonAge),
            day.moonlightLevel.label,
        ]
        if isToday { parts.append(L10n.tr("今日")) }
        return parts.joined(separator: L10n.tr("reason.separator"))
    }
}

// MARK: - Legend

private struct LunarCalendarLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.sm) { items }
            VStack(alignment: .leading, spacing: Spacing.xxs) { items }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var items: some View {
        Label(L10n.tr("暗い夜（月明かりほぼなし）"), systemImage: AppIcons.Astronomy.darkNight)
            .labelStyle(LegendLabelStyle(tint: .indigo))
        ForEach(PrincipalMoonPhase.allCases, id: \.self) { kind in
            Label(kind.name, systemImage: kind.icon)
                .labelStyle(LegendLabelStyle(tint: .yellow))
        }
    }
}

private struct LegendLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xxs) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Night Detail Panel

/// 選択した夜の月の状態と、その夜の空模様へ移動するボタン。
struct LunarNightDetailPanel: View {
    let day: LunarDay
    let timeZone: TimeZone
    let isSouthernHemisphere: Bool
    let onOpenNight: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                MoonPhaseGlyph(phase: day.phase, isSouthernHemisphere: isSouthernHemisphere, size: LunarCalendarStyle.detailGlyphSize)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(L10n.format("%@の夜", DateFormatters.yearMonthDayWeekdayString(from: day.date, timeZone: timeZone)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(day.principalEvent?.kind.name ?? MoonPhase.name(phase: day.phase))
                        .font(.title2.weight(.semibold))
                    if let event = day.principalEvent {
                        Label(
                            L10n.format(
                                "%@ %@",
                                event.kind.name,
                                DateFormatters.nightTimeString(from: event.date, timeZone: timeZone)
                            ),
                            systemImage: event.kind.icon
                        )
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(L10n.format("月齢 %.1f日", day.moonAge), systemImage: AppIcons.Astronomy.moonAge)
                Label(L10n.format("輝面比 %@", L10n.percent(day.illumination * 100)), systemImage: AppIcons.Astronomy.illumination)
                Label {
                    Text(day.moonlightLevel.label)
                } icon: {
                    Image(systemName: day.moonlightLevel.icon)
                        .foregroundStyle(day.moonlightLevel.tint)
                }
            }
            .font(.body.monospacedDigit())

            Button {
                onOpenNight(day.date)
            } label: {
                Label(L10n.tr("この夜の空模様を見る"), systemImage: AppIcons.Controls.chevronRight)
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xxs) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Style

enum LunarCalendarStyle {
    /// 7 列のグリッドが崩れない上限の文字サイズ。
    static let maximumTypeSize: DynamicTypeSize = .accessibility2
    static let navigationButtonSize: CGFloat = 44
    static let cellMinHeight: CGFloat = 64
    static let glyphSize: CGFloat = 22
    static let detailGlyphSize: CGFloat = 64
    static let eventMinimumWidth: CGFloat = 150
}

// MARK: - Preview

#Preview("東京") {
    let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let viewModel = LunarCalendarViewModel(latitude: 35.68, timeZone: timeZone, currentObservationDate: { Date() })
    return LunarCalendarPreviewContent(viewModel: viewModel)
}

#Preview("シドニー（南半球）") {
    let timeZone = TimeZone(identifier: "Australia/Sydney")!
    let viewModel = LunarCalendarViewModel(latitude: -33.87, timeZone: timeZone, currentObservationDate: { Date() })
    return LunarCalendarPreviewContent(viewModel: viewModel)
}

private struct LunarCalendarPreviewContent: View {
    @ObservedObject var viewModel: LunarCalendarViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                LunarCalendarView(viewModel: viewModel)
                if let day = viewModel.selectedDay {
                    LunarNightDetailPanel(
                        day: day,
                        timeZone: viewModel.timeZone,
                        isSouthernHemisphere: viewModel.isSouthernHemisphere,
                        onOpenNight: { _ in }
                    )
                }
            }
            .padding()
        }
        .frame(width: 420, height: 900)
    }
}
