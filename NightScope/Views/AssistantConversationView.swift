import SwiftUI

struct AssistantConversationView: View {
    @StateObject private var viewModel: AssistantConversationViewModel
    let context: AssistantConversationContext
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    init(context: AssistantConversationContext) {
        self.context = context
        _viewModel = StateObject(wrappedValue: AssistantConversationViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversationContextHeader
                conversationList
                composer
            }
            .navigationTitle(String(localized: "advice.conversation.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "advice.conversation.close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if case .streaming = viewModel.state {
                        Button(String(localized: "advice.conversation.cancel")) {
                            viewModel.cancel()
                        }
                    }
                }
            }
            .onDisappear {
                viewModel.cancel()
            }
        }
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                    if let transientNotice = viewModel.transientNotice {
                        Label(transientNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(transientNotice)
                    }
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if case .streaming(let text) = viewModel.state {
                        bubble(text: text, role: .assistant, showsTypingIndicator: true)
                            .id("streaming-response")
                    }
                    if case .error(let message) = viewModel.state {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            errorBubble(message)
                            Button(String(localized: "advice.conversation.new")) {
                                viewModel.startNewConversation()
                            }
                            .frame(minHeight: 44)
                            .glassButtonStyle()
                            .padding(.leading, Spacing.sm)
                        }
                    }
                }
                .padding(Spacing.md)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: viewModel.state) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    chip(String(localized: "advice.conversation.chip.equipment"))
                    chip(String(localized: "advice.conversation.chip.direction"))
                    chip(String(localized: "advice.conversation.chip.tomorrow"))
                }
                .padding(.horizontal, Spacing.sm)
            }

            HStack(alignment: .center, spacing: Spacing.xs) {
                TextField(
                    String(localized: "advice.conversation.placeholder"),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .glassEffectCompat(
                    in: RoundedRectangle(cornerRadius: Layout.composerCornerRadius)
                )
                .frame(minHeight: 44)
                .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(canSendDraft ? Color.accentColor : Color.secondary)
                .disabled(!canSendDraft)
                .accessibilityLabel(String(localized: "advice.conversation.send"))
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, Spacing.sm)
        }
        .disabled(isStreaming)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func chip(_ text: String) -> some View {
        Button(text) {
            viewModel.send(text)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
    }

    private func messageBubble(_ message: AssistantConversationMessage) -> some View {
        bubble(text: message.text, role: message.role)
    }

    private func bubble(
        text: String,
        role: AssistantConversationMessageRole,
        showsTypingIndicator: Bool = false
    ) -> some View {
        HStack {
            if role == .user { Spacer(minLength: Layout.bubbleMinimumSpacer) }
            HStack(alignment: .top, spacing: Spacing.xs) {
                if role == .assistant {
                    Image(systemName: AppIcons.Astronomy.sparkles)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .textSelection(.enabled)
                if showsTypingIndicator {
                    TypingIndicatorView()
                        .padding(.top, Spacing.xs)
                }
            }
            .padding(Spacing.sm)
            .background(
                role == .user
                    ? Color.accentColor.opacity(0.16)
                    : Color.secondary.opacity(0.12),
                in: bubbleShape(for: role)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(role.accessibilityLabel): \(text)"
            )
            if role == .assistant { Spacer(minLength: Layout.bubbleMinimumSpacer) }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        viewModel.send(text)
    }

    private var isStreaming: Bool {
        if case .streaming = viewModel.state { return true }
        return false
    }

    private var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if case .streaming(let text) = viewModel.state, !text.isEmpty {
            proxy.scrollTo("streaming-response", anchor: .bottom)
        } else if let lastMessage = viewModel.messages.last {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

extension AssistantConversationMessageRole {
    var accessibilityLabel: String {
        switch self {
        case .user:
            String(localized: "advice.conversation.role.you")
        case .assistant:
            String(localized: "advice.conversation.role.assistant")
        }
    }
}
