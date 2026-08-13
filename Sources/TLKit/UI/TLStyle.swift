import AppKit
import SwiftUI

/// TLKit 设计令牌（Design Tokens）。
///
/// 集中管理圆角、间距、字号层级与内容宽度，保证所有浮层与窗口
/// 遵循 Apple HIG 的视觉一致性与 8pt 间距栅格，并天然适配深浅色。
enum TLStyle {
    // MARK: - 形状

    /// Popover / 浮层圆角（HIG 标准 12pt）。
    static let cornerRadius: CGFloat = 12
    /// 浮层内部次级圆角（编辑区、卡片）。
    static let innerRadius: CGFloat = 8

    // MARK: - 尺寸

    /// 气泡面板内容宽度。
    static let bubbleWidth: CGFloat = 380
    /// 输入面板宽度（左右双栏：原文 + 译文）。
    static let inputWidth: CGFloat = 640
    /// 详细模式面板尺寸（逐句对照）。
    static let detailedWidth: CGFloat = 760
    static let detailedHeight: CGFloat = 520

    // MARK: - 间距（8pt 栅格）

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 14
    static let space5: CGFloat = 16

    // MARK: - 字号层级（SF Pro，pt）

    /// 辅助说明 / 原文摘录。
    static let caption: Font = .system(size: 12)
    /// 正文 / 译文。
    static let body: Font = .system(size: 14)
    /// 控件标签。
    static let control: Font = .system(size: 13)
    /// 强调标签（中等字重）。
    static let label: Font = .system(size: 13, weight: .medium)
    /// 底部栏极弱说明。
    static let footnote: Font = .system(size: 11)
}
