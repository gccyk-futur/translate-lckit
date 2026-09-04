import AppKit
import Foundation

/// 全局快捷键定义：keyCode + Carbon 修饰键掩码（Carbon 掩码可直接用于 RegisterEventHotKey）。
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 空快捷键（未设置）；keyCode == 0 即视为空。
    static let empty = Shortcut(keyCode: 0, carbonModifiers: 0)
    /// 默认 ⌥D（kVK_ANSI_D = 2，optionKey = 0x800）。
    static let `default` = Shortcut(keyCode: 2, carbonModifiers: 0x800)
    /// 面板内朗读默认 ⌘R（kVK_ANSI_R = 15，cmdKey = 0x100）。
    static let defaultSpeak = Shortcut(keyCode: 15, carbonModifiers: 0x100)
    /// 面板内朗读原文默认 ⇧⌘R（shiftKey = 0x200 | cmdKey = 0x100）。
    /// 约定：不加修饰键读译文，加 ⇧ 读原文（气泡的空格 / ⇧空格同理）。
    static let defaultSpeakSource = Shortcut(keyCode: 15, carbonModifiers: 0x300)
    /// 气泡内「朗读译文」默认空格（kVK_Space = 49，无修饰键）。
    static let bubbleSpeak = Shortcut(keyCode: 49, carbonModifiers: 0)
    /// 气泡内「朗读原文」默认 ⇧空格。
    static let bubbleSpeakSource = Shortcut(keyCode: 49, carbonModifiers: 0x200)
    /// 面板内切「简洁模式」默认 ⌘1（kVK_ANSI_1 = 18）。
    static let panelSimple = Shortcut(keyCode: 18, carbonModifiers: 0x100)
    /// 面板内切「逐句对照」默认 ⌘2（kVK_ANSI_2 = 19）。
    static let panelDetailed = Shortcut(keyCode: 19, carbonModifiers: 0x100)
    /// 面板内清空默认 ⌘K（kVK_ANSI_K = 40，cmdKey = 0x100）。
    static let defaultClear = Shortcut(keyCode: 40, carbonModifiers: 0x100)

    var isEmpty: Bool { keyCode == 0 && carbonModifiers == 0 }

    /// 命中判断：按键事件（已拆成原始值）是否匹配该快捷键。
    func matches(keyCode: UInt16, carbonModifiers mods: UInt32) -> Bool {
        guard !isEmpty else { return false }
        return UInt32(keyCode) == self.keyCode && mods == carbonModifiers
    }

    /// 展示用字符串，如 "⌥D"；空快捷键显示「无」。
    var displayString: String {
        guard !isEmpty else { return TLKitLocalization.string("无") }
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
    case system
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
        case .system: return TLKitLocalization.string("系统翻译")
        case .baidu: return TLKitLocalization.string("百度翻译")
        case .openai: return TLKitLocalization.string("AI 大模型")
        case .ollama: return TLKitLocalization.string("Ollama（本地）")
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
        case .system: return TLKitLocalization.string("系统语音")
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

/// 翻译目标条目：「翻译为」清单中的一行。
/// 清单第 1 条是固定默认槽（稳定 ID、不可删）：输入面板、状态栏快切、
/// 历史「重新翻译」等无快捷键上下文都以它为目标语言；其余条目是快捷键预设，
/// 「设为默认」= 把本条语言写进默认槽（不给本条打标记，避免歧义）。
struct TranslateTarget: Codable, Equatable, Identifiable {
    /// 默认槽（清单第 1 条）的稳定 ID。
    static let defaultSlotID = "default"

    var id: String
    /// 目标语言代码（如 zh / en / ja）。
    var language: String
    /// 全局快捷键；isEmpty = 无快捷键（允许清空）。
    var hotkey: Shortcut

    init(id: String = UUID().uuidString, language: String, hotkey: Shortcut = .empty) {
        self.id = id
        self.language = language
        self.hotkey = hotkey
    }
}

/// 应用配置（持久化为 Application Support/TLKit/config.json）。
/// 界面语言：跟随系统或强制指定。改动写入 AppleLanguages 默认项，重启后生效。
enum AppLanguage: String, Codable, CaseIterable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en, de, es, fr, it, ja, ko
    case ptBR = "pt-BR"

    /// 语言名用各语言自称（语言列表惯例）；「跟随系统」随界面语言。
    var label: String {
        switch self {
        case .system: return TLKitLocalization.string("跟随系统")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .ptBR: return "Português (Brasil)"
        }
    }

    /// 写入 AppleLanguages 覆盖；system 则移除覆盖（跟随 macOS）。重启后生效。
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct AppConfig: Codable, Equatable {
    /// 「翻译为」清单：第 1 条是固定默认槽（不可删），其余为快捷键预设。
    /// 2026-09 起启用的新模型：不迁移老配置键（hotkey / targetLanguage /
    /// panelTargetLanguage 已废弃，解码时直接忽略）。
    var translateTargets: [TranslateTarget] = [
        TranslateTarget(id: TranslateTarget.defaultSlotID, language: "zh", hotkey: .default)
    ]
    /// 面板内「朗读译文」快捷键（默认 ⌘R）。
    var panelSpeakHotkey: Shortcut = .defaultSpeak
    /// 面板内「朗读原文」快捷键（默认 ⇧⌘R）。
    var panelSpeakSourceHotkey: Shortcut = .defaultSpeakSource
    /// 气泡内「朗读译文」快捷键（默认空格，可在设置中改）。
    var bubbleSpeakHotkey: Shortcut = .bubbleSpeak
    /// 气泡内「朗读原文」快捷键（默认 ⇧空格，可在设置中改）。
    var bubbleSpeakSourceHotkey: Shortcut = .bubbleSpeakSource
    /// 面板内「简洁模式」快捷键（默认 ⌘1，可在设置中改）。
    var panelSimpleModeHotkey: Shortcut = .panelSimple
    /// 面板内「逐句对照」快捷键（默认 ⌘2，可在设置中改）。
    var panelDetailedModeHotkey: Shortcut = .panelDetailed
    /// 气泡「打开面板」按钮目标：true = 逐句对照（详细），false = 简洁模式。
    var bubbleOpensDetailed: Bool = true
    /// 面板内「清空输入」快捷键（默认 ⌘K）。
    var panelClearHotkey: Shortcut = .defaultClear
    /// 气泡自动消失秒数；0 = 不自动消失。
    var autoDismissSeconds: Int = 8
    var service: ServiceKind = .system
    var baidu: BaiduConfig = .init()
    var openai: OpenAIConfig = .init()
    var ollama: OllamaConfig = .init()
    /// 历史保留条数（100–5000，滚动淘汰）。
    var historyMaxCount: Int = 500
    /// TTS 配置。
    var tts: TTSConfig = .init()
    /// 外观模式：跟随系统 / 浅色 / 深色。
    var appearance: AppearanceMode = .system
    /// 界面语言：跟随系统 / 强制指定（写入 AppleLanguages，重启后生效）。
    var language: AppLanguage = .system
    /// 辅助功能「不再提醒」：true 时快捷键无权限不再弹提示，直开输入面板。
    var suppressPermissionHint: Bool = false
    /// 气泡内快捷键提示「不再提示」：true 时结果气泡不再显示快捷键小字行。
    var suppressBubbleHints: Bool = false

    // 自定义解码：缺字段时回退默认值，避免配置升级导致解析失败。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        var targets = try c.decodeIfPresent([TranslateTarget].self, forKey: .translateTargets) ?? d.translateTargets
        if targets.isEmpty {
            targets = d.translateTargets
        } else {
            // 默认槽 ID 锚定：防止手工编辑配置后「第 1 条即默认」的语义漂移。
            targets[0].id = TranslateTarget.defaultSlotID
        }
        translateTargets = targets
        panelSpeakHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .panelSpeakHotkey) ?? d.panelSpeakHotkey
        panelSpeakSourceHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .panelSpeakSourceHotkey) ?? d.panelSpeakSourceHotkey
        bubbleSpeakHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .bubbleSpeakHotkey) ?? d.bubbleSpeakHotkey
        bubbleSpeakSourceHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .bubbleSpeakSourceHotkey) ?? d.bubbleSpeakSourceHotkey
        panelSimpleModeHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .panelSimpleModeHotkey) ?? d.panelSimpleModeHotkey
        panelDetailedModeHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .panelDetailedModeHotkey) ?? d.panelDetailedModeHotkey
        bubbleOpensDetailed = try c.decodeIfPresent(Bool.self, forKey: .bubbleOpensDetailed) ?? d.bubbleOpensDetailed
        panelClearHotkey = try c.decodeIfPresent(Shortcut.self, forKey: .panelClearHotkey) ?? d.panelClearHotkey
        autoDismissSeconds = try c.decodeIfPresent(Int.self, forKey: .autoDismissSeconds) ?? d.autoDismissSeconds
        service = try c.decodeIfPresent(ServiceKind.self, forKey: .service) ?? d.service
        baidu = try c.decodeIfPresent(BaiduConfig.self, forKey: .baidu) ?? d.baidu
        openai = try c.decodeIfPresent(OpenAIConfig.self, forKey: .openai) ?? d.openai
        ollama = try c.decodeIfPresent(OllamaConfig.self, forKey: .ollama) ?? d.ollama
        historyMaxCount = try c.decodeIfPresent(Int.self, forKey: .historyMaxCount) ?? d.historyMaxCount
        tts = try c.decodeIfPresent(TTSConfig.self, forKey: .tts) ?? d.tts
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        suppressPermissionHint = try c.decodeIfPresent(Bool.self, forKey: .suppressPermissionHint) ?? d.suppressPermissionHint
        suppressBubbleHints = try c.decodeIfPresent(Bool.self, forKey: .suppressBubbleHints) ?? d.suppressBubbleHints
    }
}

extension AppConfig {
    /// 默认槽（清单第 1 条）：无快捷键上下文的目标语言来源。
    var defaultTarget: TranslateTarget {
        translateTargets.first
            ?? TranslateTarget(id: TranslateTarget.defaultSlotID, language: "zh", hotkey: .default)
    }

    /// 默认目标语言：输入面板、状态栏快切、历史「重新翻译」共用。
    var defaultTargetLanguage: String { defaultTarget.language }
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

    /// 改写默认槽语言：状态栏「翻译为」快切、面板顶栏、「设为默认」共用入口。
    func setDefaultTargetLanguage(_ language: String) {
        update { config in
            if config.translateTargets.isEmpty {
                config.translateTargets = [
                    TranslateTarget(id: TranslateTarget.defaultSlotID, language: language, hotkey: .default)
                ]
            } else {
                config.translateTargets[0].language = language
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
