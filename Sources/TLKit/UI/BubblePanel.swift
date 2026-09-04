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
    private var resignObserver: NSObjectProtocol?
    /// 当前展示的状态（空格/⇧空格朗读需要取其中的文本与语言码）。
    private var currentState: BubbleState?
    private var hovering = false

    /// 气泡内朗读回调（文本 + 语言码，由 TranslationController 注入）。
    var onSpeakRequest: ((String, String) -> Void)?
    /// 气泡「打开面板」回调（原文 + 译文，由 TranslationController 注入）。
    var onDetailedRequest: ((String, String) -> Void)?
    /// 错误态「翻译设置…」回调（由 TranslationController 注入）。
    var onOpenSettingsRequest: (() -> Void)?
    /// 权限态「不再提醒」回调（由 TranslationController 注入）。
    var onPermissionNeverRemind: (() -> Void)?

    private let panelWidth: CGFloat = TLStyle.bubbleWidth
    private let maxHeight: CGFloat = 400

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 预热：启动时建好面板与 SwiftUI 视图，首次呼出免构建开销。
    func prewarm() {
        if panel == nil { buildPanel() }
    }

    // MARK: - 展示 / 关闭

    func show(_ state: BubbleState, at mouseTopLeft: CGPoint) {
        if panel == nil { buildPanel() }
        currentState = state
        hosting?.rootView = BubbleView(state: state, onOpenAccessibility: {
            PermissionGate.openAccessibilitySettings()
        }, onSpeak: { [weak self] text, lang in
            MainActor.assumeIsolated { self?.onSpeakRequest?(text, lang) }
        }, onOpenDetailed: { [weak self] source, translation in
            MainActor.assumeIsolated { self?.onDetailedRequest?(source, translation) }
        }, onOpenSettings: { [weak self] in
            MainActor.assumeIsolated { self?.onOpenSettingsRequest?() }
        }, onNeverRemindPermission: { [weak self] in
            MainActor.assumeIsolated { self?.onPermissionNeverRemind?() }
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
        currentState = nil
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
        // 隐藏标题栏仍会向 SwiftUI 下发安全区（造成上部大空白），这里彻底关掉。
        hosting.safeAreaRegions = []
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

        // 失焦即关：气泡让出键盘焦点（点击/⌘Tab 到别处）即关闭。
        // 与倒计时自动消失互不干扰：dismiss 内部会取消 hideTask。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
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
        case .noSelection:
            seconds = 2
        case .error, .loading, .permissionNeeded:
            // 错误要留够时间阅读并点「翻译设置…」，不自动消失。
            seconds = 0
        }
        guard seconds > 0 else { return }

        hideTask = Task { [weak self] in
            var remaining = Double(seconds)
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                guard let self, self.isVisible else { return }
                // 悬停暂停倒计时；TTS 播报中同样顺延——消失会连带停止朗读，
                // 长文本播到一半被掐断（用户 2026-09-04 反馈）。
                if !self.hovering && !SpeechManager.shared.isSpeaking { remaining -= 0.2 }
            }
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    // MARK: - Esc 与点击外部关闭

    private func installMonitors() {
        removeMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc / ⌘W 关闭
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.keyCode == 13) {
                MainActor.assumeIsolated { self?.dismiss() }
                return nil
            }
            // 朗读译文 / 朗读原文（默认 空格 / ⇧空格，可在设置中改）。
            let keyCode = event.keyCode
            let mods = Shortcut.carbonModifiers(
                from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // 匹配快捷键 + 取文本都在 MainActor 域内完成；NSEvent 不可跨隔离传递。
            let outcome: (matched: Bool, utterance: (String, String)?)? = MainActor.assumeIsolated {
                guard let self else { return (false, nil) }
                let config = ConfigStore.shared.current
                let wantSource: Bool
                if config.bubbleSpeakHotkey.matches(keyCode: keyCode, carbonModifiers: mods) {
                    wantSource = false
                } else if config.bubbleSpeakSourceHotkey.matches(keyCode: keyCode, carbonModifiers: mods) {
                    wantSource = true
                } else {
                    return (false, nil)
                }
                switch self.currentState {
                case .loading(let source):
                    // 翻译中只能读原文（译文还没出来）。
                    guard !source.isEmpty else { return (true, nil) }
                    return (true, (source, TranslationController.detectLanguage(from: source)))
                case .result(let source, let translation, _, _, let sourceLang, let targetLang):
                    return (true, wantSource ? (source, sourceLang) : (translation, targetLang))
                default:
                    return (true, nil)
                }
            }
            guard let outcome, outcome.matched else { return event }
            if let utterance = outcome.utterance {
                MainActor.assumeIsolated { self?.onSpeakRequest?(utterance.0, utterance.1) }
            }
            return nil
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
