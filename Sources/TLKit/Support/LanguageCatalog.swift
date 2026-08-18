import Foundation
import NaturalLanguage

/// 语言目录与检测：设置页下拉、面板标签、TTS 选声、提示词共用。
/// 代码统一用通用两字母码（zh / en / ja…）；各翻译服务内部自行映射自家语种码。
enum LanguageCatalog {
    /// 主流语言（面向全球市场，与 TTS 支持语种对齐）。
    static let all: [(code: String, name: String)] = [
        ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("ru", "俄语"),
        ("pt", "葡萄牙语"), ("it", "意大利语"),
    ]

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
