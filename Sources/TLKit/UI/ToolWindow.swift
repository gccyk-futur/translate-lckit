import AppKit

/// 设置/历史等工具窗口：Esc（cancelOperation）直接关闭。
/// ⌘W 由主菜单「窗口 → 关闭」的 performClose: 走响应链覆盖，无需在此处理。
final class ToolWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
