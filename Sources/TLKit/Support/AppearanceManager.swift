import AppKit

/// 外观模式：跟随系统 / 浅色 / 深色。
enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// nil = 跟随系统；否则强制指定外观（影响菜单栏、窗口与所有面板）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 应用外观管理：将当前配置的外观应用到 NSApp。
///
/// 设置 `NSApp.appearance` 会级联到菜单栏 Extra、设置/历史窗口，
/// 以及懒加载的浮层面板（其 NSVisualEffectView 自动跟随 effectiveAppearance）。
@MainActor
enum AppearanceManager {
    static func apply() {
        NSApp.appearance = ConfigStore.shared.current.appearance.nsAppearance
    }
}
