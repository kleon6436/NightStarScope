import SwiftUI

// MARK: - MeteorShowerIntensity + Color (View 層のみで使用)

private extension MeteorShowerIntensity {
    var color: Color {
        switch self {
        case .high:   return .orange
        case .medium: return .blue
        case .low:    return .teal
        }
    }
}

// MARK: - MeteorShowerCalendarView

/// 流星群の年間スケジュールをガントチャート形式で表示する共有ビュー（macOS / iOS 共通）。
struct MeteorShowerCalendarView: View {
    let selectedDate: Date

    init(selectedDate: Date = Date()) {
        self.selectedDate = selectedDate
    }

    var body: some View {
        MeteorShowerCalendarContent(selectedDate: selectedDate)
            // 12 か月の目盛りと帯を 1 行に並べる表のため、これ以上大きくすると月の数字が重なる。
            // 内側の @ScaledMetric にも上限を効かせるため、中身全体の外側で指定する。
            .dynamicTypeSize(...CalendarStyle.maximumTypeSize)
    }
}

private struct MeteorShowerCalendarContent: View {

    // 月ごとの日数（非閏年）
    private static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static let totalDays = 365

    let selectedDate: Date

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var scaledLabelWidth: CGFloat = CalendarStyle.labelWidth
    @ScaledMetric(relativeTo: .caption2) private var headerHeight: CGFloat = CalendarStyle.headerHeight

    /// 大きな文字サイズでは左の名前列に群名が収まらないため、名前を帯の上に置く 2 段組みにする。
    private var usesStackedRows: Bool { dynamicTypeSize >= CalendarStyle.stackedRowsMinimumTypeSize }

    /// 帯の左に確保する名前列の幅。2 段組みでは名前を帯の上に置くので 0。
    private var labelWidth: CGFloat { usesStackedRows ? 0 : scaledLabelWidth }

    private let showers = MeteorShowerCatalog.all

    /// 選択日の day-of-year（1〜365）
    private var selectedDOY: Int {
        let cal = Calendar.current
        return MeteorShowerCatalog.dayOfYear(
            month: cal.component(.month, from: selectedDate),
            day: cal.component(.day, from: selectedDate)
        )
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader
            calendarCard
        }
    }

    // MARK: - Subviews

    private var sectionHeader: some View {
        // 見出しと補足が 1 行に並ばない文字サイズでは、補足を見出しの下へ回す。
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
        Text(L10n.tr("流星群カレンダー"))
            .font(.title3.bold())
    }

    private var sectionCaption: some View {
        Text(L10n.tr("年間スケジュール"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var calendarCard: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
                .padding(.horizontal, Spacing.xs)
            showerRowList
            Divider()
                .padding(.horizontal, Spacing.xs)
            legendRow
        }
        .padding(.vertical, Spacing.xs)
        .opaqueCardBackground(in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
    }

    private var headerRow: some View {
        GeometryReader { geo in
            let timelineWidth = timelineWidth(total: geo.size.width)
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: labelWidth)
                monthLabels(width: timelineWidth)
            }
            .padding(.horizontal, Spacing.xs)
        }
        .frame(height: headerHeight)
        .padding(.bottom, Spacing.xxs)
    }

    private func monthLabels(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<12, id: \.self) { i in
                let w = CGFloat(Self.monthDays[i]) / CGFloat(Self.totalDays) * width
                Text("\(i + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: w, alignment: .leading)
            }
        }
    }

    private var showerRowList: some View {
        ForEach(showers) { shower in
            ShowerTimelineRow(
                shower: shower,
                selectedDOY: selectedDOY,
                usesStackedLayout: usesStackedRows,
                labelWidth: labelWidth
            )

            if shower.id != showers.last?.id {
                Divider()
                    .opacity(0.4)
                    .padding(.horizontal, Spacing.xs)
            }
        }
    }

    private var legendRow: some View {
        // 1 行に収まらない文字サイズでは、強度の凡例と選択日の凡例を 2 行に分ける。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.sm) {
                Spacer(minLength: 0)
                intensityLegendItems
                selectedDateLegendItem
            }
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.sm) {
                    intensityLegendItems
                }
                selectedDateLegendItem
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
    }

    @ViewBuilder
    private var intensityLegendItems: some View {
        legendItem(color: .orange, label: L10n.tr("活発"))
        legendItem(color: .blue,   label: L10n.tr("中程度"))
        legendItem(color: .teal,   label: L10n.tr("散発的"))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
        }
        .fixedSize()
    }

    private var selectedDateLegendItem: some View {
        HStack(spacing: 3) {
            Rectangle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 1.5, height: 10)
            Text(isToday ? L10n.tr("今日") : L10n.tr("選択日"))
        }
        .fixedSize()
    }

    // MARK: - Helpers

    private func timelineWidth(total: CGFloat) -> CGFloat {
        max(0, total - labelWidth - Spacing.xs * 2)
    }
}

// MARK: - ShowerTimelineRow

private struct ShowerTimelineRow: View {
    let shower: MeteorShower
    let selectedDOY: Int
    /// true のとき群名を帯の上に置き、帯を全幅で描く。
    let usesStackedLayout: Bool
    let labelWidth: CGFloat

    @State private var isHovered = false
    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = CalendarStyle.rowHeight
    @ScaledMetric(relativeTo: .footnote) private var starIconSize: CGFloat = CalendarStyle.starIconSize

    var body: some View {
        rowContent
            .padding(.horizontal, Spacing.xs)
            .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .hoverTooltipOrTapSheet(isHovered: $isHovered) {
            hoverTooltip
        } sheet: {
            MeteorShowerDetailSheet(shower: shower)
        }
        .zIndex(isHovered ? 10 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: Hover Tooltip

    private var hoverTooltip: some View {
        let peak  = dateLabel(month: shower.peakMonth,          day: shower.peakDay)
        let start = dateLabel(month: shower.activityStartMonth, day: shower.activityStartDay)
        let end   = dateLabel(month: shower.activityEndMonth,   day: shower.activityEndDay)
        return VStack(alignment: .leading, spacing: 3) {
            Text(shower.localizedName)
                .font(.caption.bold())
            HStack(spacing: 4) {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(shower.intensity.color)
                Text("極大: \(peak)")
            }
            .font(.caption)
            Text("活動期間: \(start) 〜 \(end)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("最大 約\(shower.zhr)/h")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardSurface(cornerRadius: Layout.smallCornerRadius)
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
        .offset(y: rowHeight - 4)
        .padding(.trailing, Spacing.xs)
        .fixedSize()
    }

    private var accessibilityDescription: String {
        let start = dateLabel(month: shower.activityStartMonth, day: shower.activityStartDay)
        let end   = dateLabel(month: shower.activityEndMonth,   day: shower.activityEndDay)
        let peak  = dateLabel(month: shower.peakMonth,          day: shower.peakDay)
        return L10n.format(
            "%@、活動期間 %@から%@、極大 %@、最大 1時間あたり約%d個",
            shower.localizedName, start, end, peak, shower.zhr
        )
    }

    private func dateLabel(month: Int, day: Int) -> String {
        DateFormatters.monthDayString(month: month, day: day)
    }

    @ViewBuilder
    private var rowContent: some View {
        if usesStackedLayout {
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        showerName
                        peakRateLabel
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        showerName
                        peakRateLabel
                    }
                }
                .padding(.leading, 2)
                timelineCanvas
                    .frame(height: CalendarStyle.stackedTimelineHeight)
            }
            .padding(.vertical, Spacing.xxs)
        } else {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        showerName
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        peakRateLabel
                    }
                    .padding(.leading, 2)
                    .frame(width: labelWidth, alignment: .leading)

                    timelineCanvas
                        .frame(width: max(0, geo.size.width - labelWidth))
                }
            }
            .frame(height: rowHeight)
        }
    }

    private var timelineCanvas: some View {
        Canvas { ctx, size in
            drawRow(in: ctx, size: size)
        }
        .allowsHitTesting(false)
    }

    private var showerName: some View {
        Text(shower.localizedName)
            .font(.callout)
    }

    private var peakRateLabel: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: starIconSize))
            Text("最大 約\(shower.zhr)/h")
                .font(.footnote)
        }
        .lineLimit(1)
        .foregroundStyle(shower.intensity.color.opacity(0.9))
    }

    // MARK: Canvas Drawing

    private func drawRow(in ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let midY = h / 2

        drawTodayLine(ctx: ctx, w: w, h: h)
        drawActivityBars(ctx: ctx, w: w, midY: midY)
        drawPeakMarker(ctx: ctx, w: w, midY: midY)
    }

    private func drawTodayLine(ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        // 日の中心に今日ラインを配置
        let x = xForCenter(doy: selectedDOY, width: w)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: h))
        ctx.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 1.5)
    }

    private func drawActivityBars(ctx: GraphicsContext, w: CGFloat, midY: CGFloat) {
        let startDOY = shower.activityStartDOY
        let endDOY = shower.activityEndDOY
        let barColor = shower.intensity.color.opacity(0.3)
        let bh = CalendarStyle.barHeight
        let r = bh / 2

        if endDOY <= 365 {
            // 通常: 年内で完結
            let rect = barRect(from: startDOY, to: endDOY, midY: midY, w: w, bh: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(barColor))
        } else {
            // 年跨ぎ: 2 本に分割
            let r1 = barRect(from: startDOY, to: 365, midY: midY, w: w, bh: bh)
            ctx.fill(Path(roundedRect: r1, cornerRadius: r), with: .color(barColor))

            let r2 = barRect(from: 1, to: endDOY - 365, midY: midY, w: w, bh: bh)
            ctx.fill(Path(roundedRect: r2, cornerRadius: r), with: .color(barColor))
        }
    }

    private func drawPeakMarker(ctx: GraphicsContext, w: CGFloat, midY: CGFloat) {
        let peakDOY = MeteorShowerCatalog.dayOfYear(
            month: shower.peakMonth, day: shower.peakDay
        )
        // 日の中心に極大マーカーを配置
        let x = xForCenter(doy: peakDOY, width: w)
        let pr = CalendarStyle.peakRadius
        let rect = CGRect(x: x - pr, y: midY - pr, width: pr * 2, height: pr * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(shower.intensity.color))

        // 極大日のアウトライン
        ctx.stroke(
            Path(ellipseIn: rect),
            with: .color(.white.opacity(0.6)),
            lineWidth: 0.8
        )
    }

    // MARK: Geometry Helpers

    /// 日区間の左端 X 座標（バー描画用）。
    private func xFor(doy: Int, width: CGFloat) -> CGFloat {
        CGFloat(doy - 1) / 365.0 * width
    }

    /// 日の中心 X 座標（マーカー・今日ライン用）。
    private func xForCenter(doy: Int, width: CGFloat) -> CGFloat {
        (CGFloat(doy) - 0.5) / 365.0 * width
    }

    private func barRect(from startDOY: Int, to endDOY: Int, midY: CGFloat, w: CGFloat, bh: CGFloat) -> CGRect {
        let x = xFor(doy: startDOY, width: w)
        let endX = xFor(doy: endDOY + 1, width: w)
        return CGRect(x: x, y: midY - bh / 2, width: max(endX - x, 2), height: bh)
    }
}

// MARK: - CalendarStyle

private enum CalendarStyle {
    static let labelWidth: CGFloat = 110
    static let rowHeight: CGFloat = 44
    static let starIconSize: CGFloat = 11
    /// 2 段組みのときの帯の高さ。名前は帯の上に別行で置くので、バーとマーカーが収まれば足りる。
    static let stackedTimelineHeight: CGFloat = 20
    /// この文字サイズ以上では、名前を帯の上に置く 2 段組みにする。
    static let stackedRowsMinimumTypeSize: DynamicTypeSize = .xxLarge
    /// 12 か月の目盛りが重ならない上限の文字サイズ。
    static let maximumTypeSize: DynamicTypeSize = .accessibility2
    static let headerHeight: CGFloat = 18
    static let barHeight: CGFloat = 10
    static let peakRadius: CGFloat = 5
}

// MARK: - Preview

#Preview {
    ScrollView {
        MeteorShowerCalendarView()
            .padding()
    }
    .frame(width: 600, height: 400)
}

// MARK: - MeteorShowerDetailSheet

private struct MeteorShowerDetailSheet: View {
    let shower: MeteorShower

    var body: some View {
        let start = dateLabel(month: shower.activityStartMonth, day: shower.activityStartDay)
        let end   = dateLabel(month: shower.activityEndMonth,   day: shower.activityEndDay)
        let peak  = dateLabel(month: shower.peakMonth,          day: shower.peakDay)

        VStack(spacing: 16) {
            Text(shower.localizedName)
                .font(.title2.bold())
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(shower.intensity.color)
                    Text("極大: \(peak)")
                        .font(.headline)
                }

                Text("活動期間: \(start) 〜 \(end)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("最大 約\(shower.zhr)/h")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .presentationDetents([.fraction(0.25)])
    }

    private func dateLabel(month: Int, day: Int) -> String {
        DateFormatters.monthDayString(month: month, day: day)
    }
}
