import SwiftUI

struct ObservationAdviceCard: View {
    @ObservedObject var viewModel: ObservationAdvisorViewModel
    let input: ObservationAdvisorInput
    let toolContext: ObservationAdvisorToolContext
    let onAskMore: (ObservationAdvisorAdvice) -> Void

    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        viewModel: ObservationAdvisorViewModel,
        input: ObservationAdvisorInput,
        toolContext: ObservationAdvisorToolContext,
        onAskMore: @escaping (ObservationAdvisorAdvice) -> Void
    ) {
        self.viewModel = viewModel
        self.input = input
        self.toolContext = toolContext
        self.onAskMore = onAskMore
    }

    var body: some View {
        if shouldShowCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    CardHeader(
                        icon: AppIcons.Astronomy.sparkles,
                        iconColor: .mint,
                        title: String(localized: "advice.card.title")
                    )
                    Spacer()
                    headerAction
                }

                if let transientNotice = viewModel.transientNotice {
                    HStack(spacing: Spacing.xs) {
                        Label(transientNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(transientNotice)
                        Spacer(minLength: 0)
                        Button {
                            viewModel.dismissTransientNotice()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "advice.notice.dismiss"))
                    }
                }

                content
            }
            .glassCard()
        }
    }
}

private extension ObservationAdviceCard {
    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            Text(LocalizedStringKey("advice.card.subtitle"))
                .foregroundStyle(.secondary)
        case .loading:
            placeholder
        case .streaming(let partial):
            adviceContent(partial: partial, isStreaming: true)
        case .complete(let advice):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                adviceContent(partial: ObservationAdvisorAdvicePartial(advice), isStreaming: false)
                Button {
                    onAskMore(advice)
                } label: {
                    Label(
                        String(localized: "advice.conversation.ask_more"),
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
                .padding(.top, Spacing.xs)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(message)
                    .foregroundStyle(.secondary)
                regenerateButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable(let reason):
            unavailableContent(for: reason)
        }
    }

    @ViewBuilder
    private func adviceContent(
        partial: ObservationAdvisorAdvicePartial,
        isStreaming: Bool
    ) -> some View {
        let headline = partial.headline
        let verdict = partial.verdict.map(AdviceVerdict.init(modelValue:))
        let reasons = partial.reasons ?? []
        let tips = partial.tips ?? []
        let alternatives = isStreaming
            ? []
            : toolContext.groundedAlternatives(from: partial.alternatives)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(headline ?? String(localized: "advice.card.headline_placeholder"))
                    .font(.headline)
                    .redacted(reason: redaction(for: headline))

                Spacer(minLength: 0)

                verdictBadge(verdict: verdict)
            }

            if usesTwoColumns {
                if !reasons.isEmpty || !tips.isEmpty {
                    Divider()
                        .foregroundStyle(.secondary.opacity(0.3))
                    HStack(alignment: .top, spacing: Spacing.md) {
                        adviceColumn(
                            reasons,
                            title: String(localized: "advice.card.reasons"),
                            systemImage: "checkmark.circle"
                        )
                        adviceColumn(
                            tips,
                            title: String(localized: "advice.card.tips"),
                            systemImage: "lightbulb"
                        )
                    }
                }
            } else {
                adviceList(
                    reasons,
                    title: String(localized: "advice.card.reasons"),
                    systemImage: "checkmark.circle"
                )
                adviceList(
                    tips,
                    title: String(localized: "advice.card.tips"),
                    systemImage: "lightbulb"
                )
            }
            if verdict == .poor || verdict == .bad {
                adviceList(
                    alternatives,
                    title: String(localized: "advice.card.alternatives"),
                    systemImage: "arrow.triangle.branch"
                )
            }
            if isStreaming {
                Text(" ▍")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "advice.card.title"))
    }

    private func verdictBadge(verdict: AdviceVerdict?) -> some View {
        HStack(spacing: 4) {
            if let verdict {
                Image(systemName: "star.fill")
                    .accessibilityHidden(true)
                Text(verdict.localizedTitle)
            } else {
                Text(String(localized: "advice.card.verdict_placeholder"))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(verdict.map(verdictColor) ?? .secondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background((verdict.map(verdictColor) ?? .secondary).opacity(0.15), in: Capsule())
        .redacted(reason: verdict == nil ? .placeholder : [])
        .accessibilityLabel(verdict?.localizedTitle ?? String(localized: "advice.card.verdict_placeholder"))
    }

    @ViewBuilder
    private func adviceList(_ values: [String], title: String, systemImage: String) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Divider()
                    .foregroundStyle(.secondary.opacity(0.3))
                adviceListBody(values, title: title, systemImage: systemImage)
            }
        }
    }

    @ViewBuilder
    private func adviceColumn(_ values: [String], title: String, systemImage: String) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                adviceListBody(values, title: title, systemImage: systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func adviceListBody(_ values: [String], title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .accessibilityHidden(true)
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
                .accessibilityLabel(value)
        }
    }

    private func redaction(for value: String?) -> RedactionReasons {
        value?.isEmpty == false ? [] : .placeholder
    }

    private func verdictColor(_ verdict: AdviceVerdict) -> Color {
        switch verdict {
        case .excellent:
            .green
        case .good:
            .mint
        case .fair:
            .orange
        case .poor, .bad:
            .red
        }
    }

    private var regenerateButton: some View {
        Button {
            Task { @MainActor in
                let resolution = await viewModel.resolveModel(language: input.language)
                await viewModel.prewarm(for: toolContext, resolution: resolution)
                viewModel.generate(
                    input: input,
                    toolContext: toolContext,
                    resolution: resolution
                )
            }
        } label: {
            Label(String(localized: "advice.card.regenerate"), systemImage: "arrow.clockwise")
                #if !os(macOS)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                #endif
        }
        #if os(macOS)
        .glassButtonStyle()
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(matchesLoadingState)
    }

    @ViewBuilder
    private var headerAction: some View {
        switch viewModel.state {
        case .idle, .streaming, .complete:
            regenerateButton
        case .loading, .error, .unavailable:
            EmptyView()
        }
    }

    private var matchesLoadingState: Bool {
        if case .loading = viewModel.state {
            return true
        }
        return false
    }

    private var shouldShowCard: Bool {
        ObservationAdvisorViewModel.shouldShowCard(for: viewModel.state)
    }

    private var usesTwoColumns: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    @ViewBuilder
    private func unavailableContent(for reason: ObservationAdvisorAvailability.Reason) -> some View {
        switch reason {
        // These cases remain exhaustive even though shouldShowCard hides them.
        case .unsupportedOS, .deviceNotEligible:
            EmptyView()
        case .modelNotReady:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(LocalizedStringKey("advice.availability.model_not_ready"))
                    .foregroundStyle(.secondary)
                regenerateButton
            }
        case .appleIntelligenceOff:
            Text(LocalizedStringKey("advice.availability.apple_intelligence_off"))
                .foregroundStyle(.secondary)
        case .unknown:
            Text(String(localized: "advice.error.unavailable"))
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "advice.card.generating"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                    .fill(.quaternary)
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                    .fill(.quaternary)
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius)
                    .fill(.quaternary)
                    #if os(macOS)
                    .frame(maxWidth: 320)
                    #else
                    .frame(maxWidth: 280)
                    #endif
                    .frame(height: 16)
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "advice.card.generating"))
    }
}

#if DEBUG
#Preview("All verdicts") {
    ScrollView {
        VStack(spacing: Spacing.sm) {
            ForEach(AdviceVerdict.allCases) { verdict in
                ObservationAdviceCard(
                    viewModel: ObservationAdvisorViewModel.preview(
                        state: .complete(previewAdvice.with(verdict: verdict))
                    ),
                    input: previewInput,
                    toolContext: previewToolContext,
                    onAskMore: { _ in }
                )
            }
        }
        .padding()
    }
}

#Preview("Streaming") {
    ObservationAdviceCard(
        viewModel: ObservationAdvisorViewModel.preview(state: .streaming(
            ObservationAdvisorAdvicePartial(
                headline: "今夜は好条件",
                verdict: "good",
                bestWindow: "21:30〜23:00",
                reasons: ["雲が少ない"],
                tips: ["暗順応を待つ"]
            )
        )),
        input: previewInput,
        toolContext: previewToolContext,
        onAskMore: { _ in }
    )
    .padding()
}

private let previewInput = ObservationAdvisorInput(
    language: "ja",
    isUnfavorable: false,
    dateString: "2026年5月13日（水）",
    locationName: "長野県 乗鞍高原",
    tierLabel: "良好",
    viewingWindowSummary: "22:15〜03:30",
    moonSummary: "上弦の月",
    weatherSummary: "薄曇り",
    lightPollutionSummary: "郊外の空"
)

private let previewAdvice = ObservationAdvisorAdvice(
    headline: "今夜は観測日和",
    verdict: .excellent,
    bestWindow: "22:15〜03:30",
    reasons: ["雲が少なく透明度が良好です", "月明かりの影響が小さいです"],
    tips: ["暗順応のため15分待ちます", "南の空から天の川を探します"],
    alternatives: ["5月14日（水）・乗鞍高原"]
)

private let previewToolContext = ObservationAdvisorToolContext(
    language: "ja",
    upcomingNights: [
        UpcomingNightToolSnapshot(
            dateString: "5月14日（水）",
            locationName: "乗鞍高原",
            tier: "良好"
        )
    ]
)

private extension ObservationAdvisorAdvice {
    func with(verdict: AdviceVerdict) -> Self {
        Self(
            headline: headline,
            verdict: verdict,
            bestWindow: bestWindow,
            reasons: reasons,
            tips: tips,
            alternatives: alternatives
        )
    }
}
#endif
