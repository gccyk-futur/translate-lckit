import AppKit
import ApplicationServices

/// 辅助功能权限检测与引导。
/// 两个取词通道（模拟 ⌘C / AX 读选中文本）都需要该权限。
enum PermissionGate {
    /// 检查辅助功能权限；未授权时弹出系统授权提示。
    /// 返回当前是否已授权。
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
