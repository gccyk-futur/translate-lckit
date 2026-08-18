import XCTest

/// 纯逻辑单测：签名、快捷键模型、配置往返。
/// 被测文件直接编入测试目标（见 project.yml），不走 @testable。
@MainActor
final class TLKitTests: XCTestCase {

    // MARK: - 百度智能云 API

    func testPercentEncodePreservesSafeCharsAndEncodesSpecials() {
        XCTAssertEqual(BaiduTranslator.percentEncode("hello-world_test.~"), "hello-world_test.~")
        XCTAssertEqual(BaiduTranslator.percentEncode("a b&c=d"), "a%20b%26c%3Dd")
        // 中文必须被编码
        let encoded = BaiduTranslator.percentEncode("你好")
        XCTAssertFalse(encoded.contains("你"))
    }

    // MARK: - 快捷键模型

    func testShortcutDisplayString() {
        let shortcut = Shortcut(keyCode: 2, carbonModifiers: 0x800) // ⌥D
        XCTAssertEqual(shortcut.displayString, "⌥D")

        let complex = Shortcut(keyCode: 8, carbonModifiers: 0x100 | 0x200) // ⇧⌘C
        XCTAssertEqual(complex.displayString, "⇧⌘C")
    }

    func testCarbonModifiersFromNSEventFlags() {
        XCTAssertEqual(Shortcut.carbonModifiers(from: .command), 0x100)
        XCTAssertEqual(Shortcut.carbonModifiers(from: [.option, .shift]), 0x800 | 0x200)
        XCTAssertEqual(Shortcut.carbonModifiers(from: []), 0)
    }

    // MARK: - 配置往返

    func testAppConfigCodableRoundTrip() throws {
        var config = AppConfig()
        config.hotkey = Shortcut(keyCode: 5, carbonModifiers: 0x1000)
        config.autoDismissSeconds = 15
        config.targetLanguage = "en"
        config.baidu.apiKey = "test-api-key"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    /// 缺字段的旧配置文件应回退默认值而不是解析失败。
    func testAppConfigToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.hotkey, .default)
        XCTAssertEqual(decoded.autoDismissSeconds, 8)
        XCTAssertEqual(decoded.service, .system)
        XCTAssertEqual(decoded.historyMaxCount, 500)
        XCTAssertEqual(decoded.tts.provider, .system)
    }

    /// 旧配置文件中的 appID 字段应迁移为 apiKey（百度翻译开放平台 → 百度智能云）。
    func testBaiduConfigLegacyAppIDMigration() throws {
        let json = #"{"baidu":{"appID":"old-app-id"}}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.baidu.apiKey, "old-app-id")
    }

    // MARK: - 历史记录滚动淘汰

    func testHistoryTrimmingKeepsNewest() {
        let items = (0..<10).map {
            HistoryItem(sourceText: "s\($0)", resultText: "r\($0)", targetLang: "zh", service: "百度翻译")
        }
        let trimmed = HistoryStore.trimmed(items, maxCount: 3)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed.map(\.sourceText), ["s0", "s1", "s2"]) // items[0] 为最新（头插）
        XCTAssertEqual(HistoryStore.trimmed(items, maxCount: 0).count, 10) // 非法上限不裁剪
        XCTAssertEqual(HistoryStore.trimmed(items, maxCount: 100).count, 10)
    }

    // MARK: - OpenAI 协议端点归一化

    func testOpenAIChatEndpointNormalization() {
        XCTAssertEqual(
            OpenAICompatibleTranslator.chatEndpoint(baseURL: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.chatEndpoint(baseURL: "https://api.openai.com")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.chatEndpoint(baseURL: "http://localhost:11434/v1/")?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.chatEndpoint(baseURL: "https://x.com/v1/chat/completions")?.absoluteString,
            "https://x.com/v1/chat/completions"
        )
        XCTAssertNil(OpenAICompatibleTranslator.chatEndpoint(baseURL: "   "))
    }
}
