import Foundation
import NaturalLanguage

/// 语言目录与检测：设置页下拉、面板标签、TTS 选声、提示词共用。
/// 代码统一用通用两字母码（zh / en / ja…）；各翻译服务内部自行映射自家语种码。
enum LanguageCatalog {
    /// 主流语言（面向全球市场，与 TTS 支持语种对齐）。
    static var all: [(code: String, name: String)] {
        [
            ("zh", TLKitLocalization.string("中文")), ("en", TLKitLocalization.string("英语")),
            ("ja", TLKitLocalization.string("日语")), ("ko", TLKitLocalization.string("韩语")),
            ("fr", TLKitLocalization.string("法语")), ("de", TLKitLocalization.string("德语")),
            ("es", TLKitLocalization.string("西班牙语")), ("ru", TLKitLocalization.string("俄语")),
            ("pt", TLKitLocalization.string("葡萄牙语")), ("it", TLKitLocalization.string("意大利语")),
        ]
    }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// 检测文本语言（NaturalLanguage 框架，离线）。
    /// 返回两字母代码（如 zh / en / ja）；无法识别或超出目录时回退 en。
    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return "en" }
        let code = String(lang.rawValue.prefix(2)) // zh-Hans → zh
        return all.contains { $0.code == code } ? code : "en"
    }
}
