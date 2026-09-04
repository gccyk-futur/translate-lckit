import Foundation

/// 词典解读生成器：星标条目点一下生成详细解读，结果持久化在历史条目上。
/// 可用性不看「当前激活引擎」：只要配置完整（AI 大模型有 Base URL+模型，
/// Ollama 有模型名），就提供对应生成按钮——配置过即能用，不必先切换引擎。
/// 系统翻译与百度只能翻译、不能吃提示词，永远不在清单里（能力边界，非产品设限）。
@MainActor
enum DictionaryInterpreter {
    /// 已配置完整的 AI 引擎清单（生成按钮按此展示）。
    static var configuredEngines: [ServiceKind] {
        let config = ConfigStore.shared.current
        var kinds: [ServiceKind] = []
        if !config.openai.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
           !config.openai.model.trimmingCharacters(in: .whitespaces).isEmpty {
            kinds.append(.openai)
        }
        if !config.ollama.model.trimmingCharacters(in: .whitespaces).isEmpty {
            kinds.append(.ollama)
        }
        return kinds
    }

    /// 引擎按钮上的名字（带模型名，与气泡底栏 / 历史的展示风格一致）。
    static func engineLabel(_ kind: ServiceKind) -> String {
        let config = ConfigStore.shared.current
        switch kind {
        case .openai: return "AI · \(config.openai.model)"
        case .ollama: return "Ollama · \(config.ollama.model)"
        default: return kind.label
        }
    }

    /// 为星标条目生成词典式解读（音标/词性/释义/例句），正文使用界面语言。
    static func generate(for item: HistoryItem, using kind: ServiceKind) async throws -> String {
        let service = try ServiceFactory.make(kind)
        guard let translator = service as? OpenAICompatibleTranslator else {
            throw TranslationError.notAvailable(
                description: TLKitLocalization.string("生成解读需要 AI 大模型或 Ollama 引擎")
            )
        }
        return try await translator.chat(
            systemPrompt: systemPrompt,
            user: userContent(for: item)
        )
    }

    /// 解读正文语言 = 界面语言（解读是写给用户看的）。
    private static var uiLanguageName: String {
        let tag = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first ?? "en"
        return OpenAICompatibleTranslator.languageName(for: String(tag.prefix(2)))
    }

    private static var systemPrompt: String {
        """
        你是一本学习型词典。用户会给你一条翻译记录（原文与译文）。
        请用\(uiLanguageName)输出对原文的词典式解读，要求：
        1. 若原文是单词或短语：给出音标（如适用）、词性、核心释义；
        2. 给出 2-3 个实用例句并附\(uiLanguageName)翻译；
        3. 指出常见搭配或易混用法（如适用）；
        4. 若原文是长句或段落：改为讲解其中的语法要点与值得学习的表达。
        用纯文本小标题组织（如【释义】【例句】），篇幅控制在 300 字以内，不要使用 Markdown 标记。
        """
    }

    private static func userContent(for item: HistoryItem) -> String {
        """
        原文：\(item.sourceText)
        译文：\(item.resultText)
        """
    }
}
