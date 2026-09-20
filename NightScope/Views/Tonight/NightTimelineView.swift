import SwiftUI

/// 18:00〜翌 06:00 を 1 本の帯にして、薄明・暗夜・天の川・雲の重なりを一目で見せる。
struct NightTimelineView: View {
    /// 敷かれている面に合わせて配色を切り替える。
    enum Style {
        /// 空のグラデーションの上（明色を前提とする）。
        case onSky
        /// カード面の上（システムのセマンティックカラーに従う）。
        case onSurface
    }

    let model: NightTimelineModel
    var style: Style = .onSurface

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            GeometryReader { proxy in
                tickLabels(width: proxy.size.width)
            }
            .frame(height: Metrics.tickRowHeight)

            track

            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Tick Labels

    private func tickLabels(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.tickLabels.enumerated()), id: \.offset) { _, tick in
                Text(tick.text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .frame(width: Metrics.tickSlotWidth)
                    .offset(x: tickOffset(fraction: tick.fraction, width: width))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 目盛りラベルを比率の位置に中央寄せしつつ、両端で帯からはみ出さないよう丸める。
    private func tickOffset(fraction: Double, width: CGFloat) -> CGFloat {
        let centered = width * fraction - Metrics.tickSlotWidth / 2
        let maxOffset = max(width - Metrics.tickSlotWidth, 0)
        return min(max(centered, 0), maxOffset)
    }

    // MARK: - Track

    private var track: some View {
        Canvas { context, size in
            let shape = Path(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: Layout.innerCornerRadius,
                style: .continuous
            )
            context.clip(to: shape)
            drawTwilight(in: &context, size: size)
            drawDarkSegment(in: &context, size: size)
            drawMilkyWayBand(in: &context, size: size)
            drawCloudStrip(in: &context, size: size)
        }
        .frame(height: Metrics.trackHeight)
        .overlay {
            RoundedRectangle(cornerRadius: Layout.innerCornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: Metrics.hairline)
        }
    }

    private func drawTwilight(in context: inout GraphicsContext, size: CGSize) {
        for segment in model.twilightSegments {
            let rect = CGRect(
                x: segment.start * size.width,
                y: 0,
                width: max((segment.end - segment.start) * size.width, 0),
                height: size.height
            )
            context.fill(Path(rect), with: .color(twilightFill))
            drawHatching(in: context, rect: rect)
        }
    }

    /// 薄明帯は塗りだけだと暗夜との差が出にくいため、斜線を重ねて「まだ明るい」と伝える。
    private func drawHatching(in context: GraphicsContext, rect: CGRect) {
        // クリップは呼び出し元の context に残さないよう、複製した文脈へ適用する。
        var stripeContext = context
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += Metrics.hatchingSpacing
        }
        stripeContext.clip(to: Path(rect))
        stripeContext.stroke(
            stripes,
            with: .color(twilightStripe),
            style: StrokeStyle(lineWidth: Metrics.hairline)
        )
    }

    private func drawDarkSegment(in context: inout GraphicsContext, size: CGSize) {
        guard let dark = model.darkSegment else { return }
        let rect = CGRect(
            x: dark.startFraction * size.width,
            y: 0,
            width: max((dark.endFraction - dark.startFraction) * size.width, 0),
            height: size.height
        )
        context.fill(Path(rect), with: .color(Metrics.darkFill))

        for x in [rect.minX, rect.maxX] {
            var edge = Path()
            edge.move(to: CGPoint(x: x, y: rect.minY))
            edge.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(
                edge,
                with: .color(borderColor),
                style: StrokeStyle(lineWidth: Metrics.hairline)
            )
        }
    }

    private func drawMilkyWayBand(in context: inout GraphicsContext, size: CGSize) {
        guard let segment = model.milkyWaySegment else { return }
        let rect = CGRect(
            x: segment.start * size.width,
            y: 0,
            width: max((segment.end - segment.start) * size.width, 0),
            height: Metrics.bandHeight
        )
        context.fill(Path(rect), with: .color(Metrics.milkyWayColor))
    }

    /// 時間別サンプルを隣接する矩形に割り付け、雲量を濃さで表す。
    private func drawCloudStrip(in context: inout GraphicsContext, size: CGSize) {
        let samples = model.cloudSamples
        guard !samples.isEmpty else { return }
        for index in samples.indices {
            let sample = samples[index]
            let start = index == samples.startIndex
                ? 0
                : (samples[index - 1].fraction + sample.fraction) / 2
            let end = index == samples.index(before: samples.endIndex)
                ? 1
                : (sample.fraction + samples[index + 1].fraction) / 2
            let rect = CGRect(
                x: start * size.width,
                y: size.height - Metrics.bandHeight,
                width: max((end - start) * size.width, 0),
                height: Metrics.bandHeight
            )
            let color: Color = sample.precipitationMM > 0 ? .blue : cloudColor
            context.fill(
                Path(rect),
                with: .color(color.opacity(min(max(sample.cloudCoverPercent / 100, 0), 1)))
            )
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Array(legendTexts.enumerated()), id: \.offset) { _, text in
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(secondaryColor)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var legendTexts: [String] {
        var texts: [String] = []
        if let range = model.darkRangeText {
            texts.append(L10n.format("暗夜 %@（%@）", range, model.darkHoursText))
        }
        if let milkyWay = model.milkyWayRangeText {
            texts.append(L10n.format("天の川 %@", milkyWay))
        }
        if let average = Self.averageCloudPercent(samples: model.cloudSamples) {
            texts.append(L10n.format("雲 %@", L10n.percent(average)))
        }
        return texts
    }

    /// 時間別サンプルの平均雲量。サンプルが無ければ nil。
    static func averageCloudPercent(
        samples: [(fraction: Double, cloudCoverPercent: Double, precipitationMM: Double)]
    ) -> Double? {
        guard !samples.isEmpty else { return nil }
        let total = samples.reduce(0) { $0 + $1.cloudCoverPercent }
        return total / Double(samples.count)
    }

    // MARK: - Style

    private var secondaryColor: Color {
        switch style {
        case .onSky:     return .white.opacity(0.82)
        case .onSurface: return .secondary
        }
    }

    private var borderColor: Color {
        switch style {
        case .onSky:     return .white.opacity(0.22)
        case .onSurface: return .primary.opacity(0.12)
        }
    }

    private var twilightFill: Color {
        switch style {
        case .onSky:     return .white.opacity(0.12)
        case .onSurface: return .primary.opacity(0.06)
        }
    }

    private var twilightStripe: Color {
        switch style {
        case .onSky:     return .white.opacity(0.18)
        case .onSurface: return .primary.opacity(0.12)
        }
    }

    private var cloudColor: Color {
        switch style {
        case .onSky:     return .white
        case .onSurface: return .secondary
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts = [
            L10n.format("暗夜 %@", model.darkRangeText ?? L10n.tr("暗い時間なし"))
        ]
        if let milkyWay = model.milkyWayRangeText {
            parts.append(L10n.format("天の川 %@", milkyWay))
        }
        return L10n.tr("夜のタイムライン") + "。" + parts.joined(separator: "。")
    }

    private enum Metrics {
        static let trackHeight: CGFloat = 40
        static let tickRowHeight: CGFloat = 14
        static let tickSlotWidth: CGFloat = 44
        static let rowSpacing: CGFloat = 6
        static let bandHeight: CGFloat = 6
        static let hairline: CGFloat = 1
        static let hatchingSpacing: CGFloat = 8
        /// 天文薄明が終わった時間帯。星図の夜空と同系の濃紺。
        static let darkFill = Color(red: 0.04, green: 0.07, blue: 0.19)
        /// 天の川バンド。要約カードのアクセントと合わせる。
        static let milkyWayColor = Color.indigo.opacity(0.9)
    }
}
