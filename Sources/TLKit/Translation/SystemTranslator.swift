import Foundation
import Translation

/// 系统翻译器：macOS 内置 Translation 框架（设备端、免费、免配置）。
/// 直接构造 TranslationSession 需要 macOS 26+；首次翻译某语言对时
/// 系统可能引导下载语言模型（系统设置 → 通用 → 语言与地区 → 翻译语言）。
@available(macOS 26.0, *)
struct SystemTranslator: TranslationService {
    let displayName = TLKitLocalization.string("系统翻译")

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        // 直接 init 必须显式给出源语言：手动指定优先，否则 NaturalLanguage 检测，失败回退英语。
        let sourceCode = source ?? LanguageCatalog.detect(text)
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: target)
        )
        do {
            let response = try await session.translate(text)
            let result = response.targetText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !result.isEmpty else { throw TranslationError.emptyResult }
            return result
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError.network(
                message: TLKitLocalization.format("系统翻译失败：%@。", error.localizedDescription)
                    + TLKitLocalization.string("可在「系统设置 → 通用 → 语言与地区 → 翻译语言」确认已下载对应语言模型。")
            )
        }
    }
}
