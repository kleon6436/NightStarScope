import SwiftUI

struct AssistantConversationView: View {
    @StateObject private var viewModel: AssistantConversationViewModel
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    init(context: AssistantConversationContext) {
        _viewModel = StateObject(wrappedValue: AssistantConversationViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                    if case .streaming(let text) = viewModel.state, !text.isEmpty {
                        bubble(text: text, role: .assistant)
                            .id("streaming-response")
                    }
                    if case .error(let message) = viewModel.state {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(message)
                            Button(String(localized: "advice.conversation.new")) {
                                viewModel.startNewConversation()
                            }
                            .frame(minHeight: 44)
                        }
                        .padding(.horizontal, Spacing.sm)
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

            HStack(alignment: .bottom, spacing: Spacing.xs) {
                TextField(
                    String(localized: "advice.conversation.placeholder"),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(String(localized: "advice.conversation.send"))
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, Spacing.sm)
        }
        .disabled(isStreaming)
        .background(.bar)
    }

    private func chip(_ text: String) -> some View {
        Button(text) {
            viewModel.send(text)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private func messageBubble(_ message: AssistantConversationMessage) -> some View {
        bubble(text: message.text, role: message.role)
    }

    private func bubble(
        text: String,
        role: AssistantConversationMessageRole
    ) -> some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            Text(text)
                .textSelection(.enabled)
                .padding(Spacing.sm)
                .background(role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
                .accessibilityLabel(text)
            if role == .assistant { Spacer(minLength: 40) }
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

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if case .streaming(let text) = viewModel.state, !text.isEmpty {
            proxy.scrollTo("streaming-response", anchor: .bottom)
        } else if let lastMessage = viewModel.messages.last {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}
