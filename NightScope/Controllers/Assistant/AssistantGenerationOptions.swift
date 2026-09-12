#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
enum AssistantGenerationOptions {
    // Structured advice has a bounded schema; 400 tokens leave room for all guided fields.
    static let adviceMaximumResponseTokens = 400
    static let conversationMaximumResponseTokens = 500

    static func adviceGenerationOptions() -> GenerationOptions {
        if #available(macOS 27.0, iOS 27.0, *) {
            return GenerationOptions(
                samplingMode: .greedy,
                temperature: nil,
                maximumResponseTokens: adviceMaximumResponseTokens,
                toolCallingMode: .allowed
            )
        }

        return GenerationOptions(
            samplingMode: .greedy,
            temperature: nil,
            maximumResponseTokens: adviceMaximumResponseTokens
        )
    }

    static func conversationGenerationOptions() -> GenerationOptions {
        GenerationOptions(
            samplingMode: nil,
            temperature: nil,
            maximumResponseTokens: conversationMaximumResponseTokens
        )
    }

    @available(macOS 27.0, iOS 27.0, *)
    static func contextOptions(for kind: AssistantModelKind) -> ContextOptions {
        if kind == .privateCloud {
            return ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .moderate)
        }

        // ContextOptionsのreasoningLevelは型上SystemLanguageModelにも適用可能。capabilities.contains(.reasoning)で実サポート有無を実行時確認してから設定する。
        if SystemLanguageModel.default.capabilities.contains(.reasoning) {
            return ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light)
        }

        return ContextOptions(includeSchemaInPrompt: true)
    }
}
#endif
