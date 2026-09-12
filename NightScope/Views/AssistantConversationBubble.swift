import SwiftUI

extension AssistantConversationView {
    var conversationContextHeader: some View {
        Group {
            if !context.headline.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: AppIcons.Astronomy.sparkles)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(context.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(localized: "advice.conversation.context") + ": " + context.headline
                )
            }
        }
    }

    func errorBubble(_ message: String) -> some View {
        HStack {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: AppIcons.Status.warning)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
            }
            .padding(Spacing.sm)
            .background(Color.secondary.opacity(0.12), in: bubbleShape(for: .assistant))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(AssistantConversationMessageRole.assistant.accessibilityLabel): \(message)")
            Spacer(minLength: Layout.bubbleMinimumSpacer)
        }
    }

    func bubbleShape(for role: AssistantConversationMessageRole) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: Layout.bubbleCornerRadius,
                bottomLeading: role == .assistant
                    ? Layout.bubbleTailCornerRadius
                    : Layout.bubbleCornerRadius,
                bottomTrailing: role == .user
                    ? Layout.bubbleTailCornerRadius
                    : Layout.bubbleCornerRadius,
                topTrailing: Layout.bubbleCornerRadius
            )
        )
    }
}

struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: Spacing.xs / 2) {
            ForEach(0..<Layout.typingIndicatorDotCount, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(
                        width: Layout.typingIndicatorDotSize,
                        height: Layout.typingIndicatorDotSize
                    )
                    .opacity(reduceMotion ? 0.65 : (isAnimating ? 0.35 : 1))
                    .animation(
                        reduceMotion
                            ? .none
                            : .easeInOut(duration: Layout.typingIndicatorAnimationDuration)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * Layout.typingIndicatorAnimationDelay),
                        value: isAnimating
                    )
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            isAnimating = true
        }
        .onChange(of: reduceMotion) { _, isReduced in
            isAnimating = !isReduced
        }
    }
}
