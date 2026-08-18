import AppKit
import ApplicationServices

/// AX 直读结果（三态，用于决定是否回退模拟 ⌘C）。
enum AXSelectionResult {
    /// 读到选中文字。
    case text(String)
    /// AX 通道工作正常，但当前确实无选中内容 —— 不应回退 ⌘C
    ///（否则 VS Code 当前行等「隐式拷贝」会被误当成选中文字）。
    case noSelection
    /// 应用不响应 AX 读取（部分 Electron 等），需回退模拟 ⌘C。
    case unavailable
}

/// 通道 B：Accessibility API 直读前台应用的选中文字（直装版优先通道）。
///
/// 相比模拟 ⌘C：
/// - 真·选中内容：无选中即空，不受应用「隐式拷贝」行为干扰；
/// - 不读写剪贴板：省掉备份/轮询/还原，毫秒级返回。
@MainActor
final class AXSelectionReader {

    func readSelection() -> AXSelectionResult {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return .unavailable
        }
        let app = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else {
            // 取不到焦点元素：应用不响应 AX，回退 ⌘C。
            return .unavailable
        }

        // swiftlint:disable:next force_cast — AXUIElement 为 CF 类型，桥接转换安全。
        let focused = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &valueRef) {
        case .success:
            guard let text = valueRef as? String, !text.isEmpty else { return .noSelection }
            return .text(text)
        case .noValue:
            // 属性存在但当前无值 = 无选中。
            return .noSelection
        default:
            // .attributeUnsupported / .failure 等：应用不支持直读，回退 ⌘C。
            return .unavailable
        }
    }
}
