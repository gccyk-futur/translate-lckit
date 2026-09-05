import Foundation

/// 取词通道协议：从当前前台应用读取用户选中的文字。
///
/// 官网版（持有辅助功能权限）：AX 直读优先，应用不响应 AX 时回退模拟 ⌘C。
/// App Store 版默认不走取词（审核条款 2.4.5），快捷键直接打开输入面板；
/// 用户自行授予辅助功能权限后由 TranslationController 落入同样的取词路径。
@MainActor
protocol SelectionReader {
    /// 读取选中文本；无选中内容或读取失败返回 nil。
    func readSelection() async -> String?
}

/// 组合通道：AX 直读优先；AX 不可用（应用不支持）时回退模拟 ⌘C。
/// AX 确认无选中时直接返回 nil，不回退 —— 避免把隐式拷贝误当选中。
@MainActor
final class FallbackSelectionReader: SelectionReader {
    private let ax = AXSelectionReader()
    private let clipboard = ClipboardSelectionReader()

    func readSelection() async -> String? {
        switch ax.readSelection() {
        case .text(let text):
            return text
        case .noSelection:
            return nil
        case .unavailable:
            return await clipboard.readSelection()
        }
    }
}

/// 取词通道工厂。
enum SelectionReaderFactory {
    static func make() -> SelectionReader {
        FallbackSelectionReader()
    }
}
