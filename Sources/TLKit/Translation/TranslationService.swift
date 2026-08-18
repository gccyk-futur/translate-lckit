import Foundation

/// 翻译服务统一协议。
protocol TranslationService: Sendable {
    var displayName: String { get }
    func translate(_ text: String, to target: String) async throws -> String
}

enum TranslationError: LocalizedError {
    /// 服务未配置完整（缺 App ID / 密钥）。
    case notConfigured(serviceName: String)
    /// 该服务当前版本尚未实现。
    case notAvailable(description: String)
    /// 服务端返回错误。
    case server(message: String)
    /// 网络错误 / 超时。
    case network(message: String)
    /// 服务未返回译文。
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notConfigured(let name):
            return "请先在设置中完成「\(name)」的配置"
        case .notAvailable(let description):
            return description
        case .server(let message):
            return "翻译服务返回错误：\(message)"
        case .network(let message):
            return "网络请求失败：\(message)"
        case .emptyResult:
            return "翻译服务未返回结果"
        }
    }
}

/// 根据当前配置构造翻译服务实例。
@MainActor
enum ServiceFactory {
    static func makeActive() throws -> TranslationService {
        try make(ConfigStore.shared.current.service)
    }

    /// 按指定种类构造（设置页「测试连接」用，可与当前激活服务不同）。
    static func make(_ kind: ServiceKind) throws -> TranslationService {
        let config = ConfigStore.shared.current
        switch kind {
        case .system:
            if #available(macOS 26.0, *) {
                return SystemTranslator()
            }
            throw TranslationError.notAvailable(description: "系统翻译需要 macOS 26 及以上版本，请改用百度翻译或大模型服务")
        case .baidu:
            let apiKey = config.baidu.apiKey.trimmingCharacters(in: .whitespaces)
            let secret = (KeychainStore.get(.baiduSecret) ?? "").trimmingCharacters(in: .whitespaces)
            guard !apiKey.isEmpty, !secret.isEmpty else {
                throw TranslationError.notConfigured(serviceName: "百度翻译")
            }
            return BaiduTranslator(apiKey: apiKey, secretKey: secret)
        case .openai:
            let baseURL = config.openai.baseURL.trimmingCharacters(in: .whitespaces)
            let model = config.openai.model.trimmingCharacters(in: .whitespaces)
            guard !baseURL.isEmpty, !model.isEmpty else {
                throw TranslationError.notConfigured(serviceName: "AI 大模型")
            }
            return OpenAICompatibleTranslator(
                // 模型服务展示名带上模型名（气泡底栏 / 历史可见）。
                displayName: "AI · \(model)",
                baseURL: baseURL,
                apiKey: KeychainStore.get(.openaiKey) ?? "",
                model: model
            )
        case .ollama:
            let host = config.ollama.host.trimmingCharacters(in: .whitespaces)
            let model = config.ollama.model.trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else {
                throw TranslationError.notConfigured(serviceName: "Ollama")
            }
            return OpenAICompatibleTranslator(
                displayName: "Ollama · \(model)",
                baseURL: host.isEmpty ? "http://localhost:11434" : host,
                apiKey: "",
                model: model
            )
        }
    }
}
