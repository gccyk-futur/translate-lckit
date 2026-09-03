import Foundation

/// OpenAI Chat Completions 协议翻译器。
/// 同时覆盖三类端点：OpenAI 官方、第三方兼容 API、Ollama（本地 /v1）。
struct OpenAICompatibleTranslator: TranslationService {
    let displayName: String
    let baseURL: String
    let apiKey: String
    let model: String

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        guard let url = Self.chatEndpoint(baseURL: baseURL) else {
            throw TranslationError.network(message: TLKitLocalization.format("%@ Base URL 无效", displayName))
        }
        guard !model.isEmpty else {
            throw TranslationError.notConfigured(serviceName: displayName)
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload = RequestPayload(
            model: model,
            temperature: 0.3,
            messages: [
                .init(role: "system", content: Self.systemPrompt(from: source, to: target)),
                .init(role: "user", content: text),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.network(message: TLKitLocalization.format("%@ 响应异常", displayName))
        }

        if let decoded = try? JSONDecoder().decode(ResponsePayload.self, from: data) {
            if let error = decoded.error {
                throw TranslationError.server(message: TLKitLocalization.format("%@（HTTP %lld）", error.message, http.statusCode))
            }
            if let content = decoded.choices?.first?.message.content {
                let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty { return result }
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslationError.server(message: TLKitLocalization.format("HTTP %lld：%@", http.statusCode, String(data: data, encoding: .utf8) ?? ""))
        }
        throw TranslationError.emptyResult
    }

    /// 兼容多种 Base URL 写法：带 /v1、不带 /v1、直接写到 /chat/completions。
    static func chatEndpoint(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        if base.hasSuffix("/v1") {
            return URL(string: base + "/chat/completions")
        }
        return URL(string: base + "/v1/chat/completions")
    }

    /// 系统提示词（设置页只读展示，与请求实际使用的一致）。
    static func systemPrompt(for target: String) -> String {
        systemPrompt(from: nil, to: target)
    }

    /// 带可选源语言的提示词：手动指定源语言时写入 prompt，纠正自动检测误判。
    static func systemPrompt(from source: String?, to target: String) -> String {
        let targetName = languageName(for: target)
        if let source {
            return "你是一个翻译引擎。把用户发送的\(languageName(for: source))文本翻译成\(targetName)。只输出译文，不要解释，不要复述原文。"
        }
        return "你是一个翻译引擎。把用户发送的文本翻译成\(targetName)。只输出译文，不要解释，不要复述原文。"
    }

    static func languageName(for code: String) -> String {
        switch code.lowercased() {
        case "zh": return "中文"
        case "en": return "英文"
        case "ja": return "日文"
        case "ko": return "韩文"
        case "fra", "fr": return "法文"
        case "de": return "德文"
        case "spa", "es": return "西班牙文"
        case "ru": return "俄文"
        case "pt": return "葡萄牙文"
        case "it": return "意大利文"
        default: return "语言代码 \(code) 对应的语言"
        }
    }

    // MARK: - 请求/响应结构

    private struct RequestPayload: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let temperature: Double
        let messages: [Message]
    }

    private struct ResponsePayload: Decodable {
        struct Message: Decodable {
            let content: String
        }

        struct Choice: Decodable {
            let message: Message
        }

        struct ErrorPayload: Decodable {
            let message: String
        }

        let choices: [Choice]?
        let error: ErrorPayload?
    }
}
