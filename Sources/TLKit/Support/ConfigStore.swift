import AppKit
import Foundation

/// 全局快捷键定义：keyCode + Carbon 修饰键掩码（Carbon 掩码可直接用于 RegisterEventHotKey）。
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 默认 ⌥D（kVK_ANSI_D = 2，optionKey = 0x800）。
    static let `default` = Shortcut(keyCode: 2, carbonModifiers: 0x800)

    var isEmpty: Bool { keyCode == 0 && carbonModifiers == 0 }

    /// 展示用字符串，如 "⌥D"。
    var displayString: String {
        var s = ""
        if carbonModifiers & 0x1000 != 0 { s += "⌃" } // controlKey
        if carbonModifiers & 0x800 != 0 { s += "⌥" }  // optionKey
        if carbonModifiers & 0x200 != 0 { s += "⇧" }  // shiftKey
        if carbonModifiers & 0x100 != 0 { s += "⌘" }  // cmdKey
        s += Self.keyName(for: keyCode)
        return s
    }

    /// 常见 keyCode → 字符（覆盖字母/数字/常用符号，未知键回退为码值）。
    static func keyName(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 118: "F4", 120: "F2", 122: "F1",
            36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }

    /// NSEvent 修饰键 → Carbon 掩码。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= 0x100 }
        if flags.contains(.shift) { m |= 0x200 }
        if flags.contains(.option) { m |= 0x800 }
        if flags.contains(.control) { m |= 0x1000 }
        return m
    }
}

enum ServiceKind: String, Codable, CaseIterable {
    case baidu
    case openai
    case ollama

    /// 所有渠道均提供全部服务。App Store 版仅文案措辞不同：
    /// UI 不出现「OpenAI」字样（避免国内区审核敏感词），统一称「AI 大模型」。
    static var availableCases: [ServiceKind] {
        ServiceKind.allCases
    }

    var label: String {
        switch self {
        case .baidu: return "百度翻译"
        case .openai: return "AI 大模型"
        case .ollama: return "Ollama（本地）"
        }
    }
}

/// 翻译方向（输入面板用，也可配置默认值）。
enum TranslationDirection: String, Codable, CaseIterable {
    case en2zh
    case zh2en

    var label: String {
        switch self {
        case .en2zh: return "英 → 中"
        case .zh2en: return "中 → 英"
        }
    }

    var sourceLabel: String { self == .en2zh ? "英文" : "中文" }
    var targetLabel: String { self == .en2zh ? "中文" : "英文" }

    /// 对应的源语言代码。
    var sourceLanguage: String { self == .en2zh ? "en" : "zh" }

    /// 交换方向后的值（面板「⇄」按钮用）。
    var swapped: TranslationDirection { self == .en2zh ? .zh2en : .en2zh }

    /// 对应的目标语言代码（Baidu `to` 参数）。
    var targetLanguage: String {
        switch self {
        case .en2zh: return "zh"
        case .zh2en: return "en"
        }
    }

}

struct BaiduConfig: Codable, Equatable {
    var apiKey: String = ""
    // Secret Key 存 Keychain（KeychainKey.baiduSecret），不落配置文件。

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        // 兼容旧字段名 appID（百度翻译开放平台 → 百度智能云迁移）
        if apiKey.isEmpty {
            if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
               let oldID = try? legacy.decodeIfPresent(String.self, forKey: .appID) {
                apiKey = oldID
            }
        }
    }

    enum CodingKeys: String, CodingKey { case apiKey }
    enum LegacyKeys: String, CodingKey { case appID }
}

struct OpenAIConfig: Codable, Equatable {
    var baseURL: String = ""
    var model: String = ""
}

struct OllamaConfig: Codable, Equatable {
    var host: String = "http://localhost:11434"
    var model: String = ""
}

/// TTS 服务选择。
enum TTSProvider: String, Codable, CaseIterable {
    case system
    case azure

    var label: String {
        switch self {
        case .system: return "系统语音"
        case .azure: return "Microsoft Azure"
        }
    }
}

/// 语音配置；Azure Key 不入此结构（存 Keychain）。
struct TTSConfig: Codable, Equatable {
    var provider: TTSProvider = .system
    var azureRegion: String = ""
    /// 朗读速度倍率（0.5 ~ 2.0，默认 1.0）。
    var speechRate: Float = 1.0
    /// 系统语音 identifier；空串 = 按语言自动选。
    var systemVoice: String = ""
    /// Azure 神经语音（如 zh-CN-XiaoxiaoNeural）；空串 = 按语言自动选。
    var azureVoice: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TTSConfig()
        provider = try c.decodeIfPresent(TTSProvider.self, forKey: .provider) ?? d.provider
        azureRegion = try c.decodeIfPresent(String.self, forKey: .azureRegion) ?? d.azureRegion
        speechRate = try c.decodeIfPresent(Float.self, forKey: .speechRate) ?? d.speechRate
        systemVoice = try c.decodeIfPresent(String.self, forKey: .systemVoice) ?? d.systemVoice
        azureVoice = try c.decodeIfPresent(String.self, forKey: .azureVoice) ?? d.azureVoice
    }
}

/// 应用配置（持久化为 Application Support/TLKit/config.json）。
struct AppConfig: Codable, Equatable {
    var hotkey: Shortcut = .default
    /// 气泡自动消失秒数；0 = 不自动消失。
    var autoDismissSeconds: Int = 8
    /// 翻译目标语言（百度语种代码，如 zh / en）。
    var targetLanguage: String = "zh"
    var service: ServiceKind = .baidu
    var baidu: BaiduConfig = .init()
    var openai: OpenAIConfig = .init()
    var ollama: OllamaConfig = .init()
    /// 历史保留条数（100–5000，滚动淘汰）。
    var historyMaxCount: Int = 500
    /// TTS 配置。
    var tts: TTSConfig = .init()
    /// 输入面板默认翻译方向。
    var defaultDirection: TranslationDirection = .en2zh
    /// 外观模式：跟随系统 / 浅色 / 深色。
    var appearance: AppearanceMode = .system

    // 自定义解码：缺字段时回退默认值，避免配置升级导致解析失败。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        hotkey = try c.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? d.hotkey
        autoDismissSeconds = try c.decodeIfPresent(Int.self, forKey: .autoDismissSeconds) ?? d.autoDismissSeconds
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        service = try c.decodeIfPresent(ServiceKind.self, forKey: .service) ?? d.service
        baidu = try c.decodeIfPresent(BaiduConfig.self, forKey: .baidu) ?? d.baidu
        openai = try c.decodeIfPresent(OpenAIConfig.self, forKey: .openai) ?? d.openai
        ollama = try c.decodeIfPresent(OllamaConfig.self, forKey: .ollama) ?? d.ollama
        historyMaxCount = try c.decodeIfPresent(Int.self, forKey: .historyMaxCount) ?? d.historyMaxCount
        tts = try c.decodeIfPresent(TTSConfig.self, forKey: .tts) ?? d.tts
        defaultDirection = try c.decodeIfPresent(TranslationDirection.self, forKey: .defaultDirection) ?? d.defaultDirection
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
    }
}

/// Keychain 存储键。
enum KeychainKey: String {
    case baiduSecret
    case openaiKey
    case azureKey
}

/// 配置存取中枢：JSON 落盘，敏感 Key 走 Keychain。
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var current: AppConfig

    private let fileURL: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TLKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            current = decoded
        } else {
            current = AppConfig()
        }
    }

    /// 修改配置并落盘。
    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&current)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
