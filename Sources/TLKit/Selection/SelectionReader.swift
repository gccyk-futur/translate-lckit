import Foundation

/// 取词通道协议：从当前前台应用读取用户选中的文字。
///
/// 统一使用 `ClipboardSelectionReader`（模拟 ⌘C + 剪贴板），兼容所有应用
/// （Chrome、Electron、Safari 等），直装版和沙盒版通用。
/// CGEvent.post() 走 PostEvent TCC 权限（与 Accessibility API 独立），沙盒下可用。
@MainActor
protocol SelectionReader {
    /// 读取选中文本；无选中内容或读取失败返回 nil。
    func readSelection() async -> String?
}

/// 取词通道工厂：统一返回 ClipboardSelectionReader。
enum SelectionReaderFactory {
    static func make() -> SelectionReader {
        ClipboardSelectionReader()
    }
}
