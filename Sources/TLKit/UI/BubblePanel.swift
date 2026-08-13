import AppKit
import SwiftUI

/// 气泡面板：nonactivating NSPanel，不抢当前应用焦点。
final class BubblePanel: NSPanel {
    var onHoverChange: ((Bool) -> Void)? {
        didSet { hoverEffectView?.onHoverChange = onHoverChange }
    }
    private var hoverEffectView: HoverEffectView?

    func setHoverEffectView(_ view: HoverEffectView) {
        hoverEffectView = view
        view.onHoverChange = onHoverChange
    }
}

/// 毛玻璃背景视图：附带悬停追踪（用于自动消失的暂停/恢复）。
final class HoverEffectView: NSVisualEffectView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// 气泡面板控制器：展示、定位（鼠标附近）、自动消失（悬停暂停）、Esc/点击外部关闭。
///
/// 面板配方（实测验证）：
/// - styleMask [.nonactivatingPanel, .titled, .fullSizeContentView] + 透明标题栏
/// - level .popUpMenu、collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]
/// - NSVisualEffectView(.popover) 毛玻璃背景
@MainActor
final class BubblePanelController {
    private var panel: BubblePanel?
    private var hosting: NSHostingView<BubbleView>?
    private var hideTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var hovering = false

    /// 气泡内朗读按钮回调（由 TranslationController 注入）。
    var onSpeakRequest: ((String) -> Void)?
    /// 气泡「详细对照」回调（由 TranslationController 注入）。
    var onDetailedRequest: ((String) -> Void)?

    private let panelWidth: CGFloat = TLStyle.bubbleWidth
    private let maxHeight: CGFloat = 400

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 展示 / 关闭

    func show(_ state: BubbleState, at mouseTopLeft: CGPoint) {
        if panel == nil { buildPanel() }
        hosting?.rootView = BubbleView(state: state, onOpenAccessibility: {
            PermissionGate.openAccessibilitySettings()
        }, onSpeak: { [weak self] text in
            MainActor.assumeIsolated { self?.onSpeakRequest?(text) }
        }, onOpenDetailed: { [weak self] text in
            MainActor.assumeIsolated { self?.onDetailedRequest?(text) }
        })
        layoutAndPosition(at: mouseTopLeft)
        panel?.orderFrontRegardless()
        panel?.makeKey()
        installMonitors()
        scheduleAutoHide(for: state)
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        removeMonitors()
        SpeechManager.shared.stop()
        panel?.orderOut(nil)
    }

    // MARK: - 构建

    private func buildPanel() {
        let panel = BubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(panelWidth), height: 80),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = HoverEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = TLStyle.cornerRadius
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: BubbleView(state: .noSelection))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        panel.setHoverEffectView(effect)
        panel.onHoverChange = { [weak self] hovering in
            MainActor.assumeIsolated { self?.hovering = hovering }
        }

        self.panel = panel
        self.hosting = hosting
    }

    // MARK: - 布局与定位

    /// mouseTopLeft 为 CGEvent 全局坐标（左上角原点）。
    private func layoutAndPosition(at mouseTopLeft: CGPoint) {
        guard let panel, let hosting, let primary = NSScreen.screens.first else { return }

        hosting.frame.size = CGSize(width: panelWidth, height: hosting.frame.height)
        hosting.layoutSubtreeIfNeeded()
        let height = min(max(hosting.fittingSize.height, 44), maxHeight)

        let globalHeight = primary.frame.maxY

        func topLeftFrame(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.origin.x,
                   y: globalHeight - rect.origin.y - rect.height,
                   width: rect.width, height: rect.height)
        }

        let screen = NSScreen.screens.first { topLeftFrame($0.frame).contains(mouseTopLeft) } ?? primary
        let visible = topLeftFrame(screen.visibleFrame)

        var x = mouseTopLeft.x + 4
        if x + panelWidth > visible.maxX - 8 { x = visible.maxX - panelWidth - 8 }
        if x < visible.minX + 8 { x = visible.minX + 8 }

        // 默认置于鼠标下方；放不下则置于上方。
        var topY = mouseTopLeft.y + 22
        if topY + height > visible.maxY - 8 {
            topY = mouseTopLeft.y - height - 6
        }
        if topY < visible.minY + 8 { topY = visible.minY + 8 }

        let originY = globalHeight - topY - height
        panel.setFrame(NSRect(x: x, y: originY, width: panelWidth, height: height), display: true)
    }

    // MARK: - 自动消失（悬停暂停）

    private func scheduleAutoHide(for state: BubbleState) {
        hideTask?.cancel()
        hideTask = nil

        let seconds: Int
        switch state {
        case .result:
            seconds = ConfigStore.shared.current.autoDismissSeconds
        case .error, .noSelection:
            seconds = 2
        case .loading, .permissionNeeded:
            seconds = 0
        }
        guard seconds > 0 else { return }

        hideTask = Task { [weak self] in
            var remaining = Double(seconds)
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                guard let self, self.isVisible else { return }
                if !self.hovering { remaining -= 0.2 }
            }
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    // MARK: - Esc 与点击外部关闭

    private func installMonitors() {
        removeMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.dismiss() }
                return nil
            }
            return event
        }

        // 本应用其他窗口上的点击。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                self.dismiss()
            }
            return event
        }

        // 其他应用上的点击（全局监听鼠标事件无需辅助功能权限）。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
    }
}
