import AppKit

/// ⌘Q 退出确认：高频工具常驻后台，一次误按 ⌘Q 就静默退出太伤。
@MainActor
enum QuitGuard {
    static func confirm() {
        let alert = NSAlert()
        alert.messageText = TLKitLocalization.string("确定退出 TLKit？")
        alert.informativeText = TLKitLocalization.string("退出后全局快捷键与翻译面板将不可用。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: TLKitLocalization.string("退出"))
        alert.addButton(withTitle: TLKitLocalization.string("取消"))
        // 翻译面板是 .popUpMenu 层级，确认框要再抬一级，否则被面板压在后面。
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

/// 应用代理：菜单栏 Agent（LSUIElement），启动时建菜单栏状态项、注册快捷键。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        TranslationController.shared.start()
        AppearanceManager.apply()
        #if DEBUG
        // 截图演示入口（仅 Debug）：TLKIT_DEMO=input / input-detailed / settings-<paneRawValue>
        if let demo = ProcessInfo.processInfo.environment["TLKIT_DEMO"] {
            print("[TLKIT_DEMO] trigger: \(demo)")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                switch demo {
                case "input":
                    InputPanelController.shared.show()
                    InputPanelController.shared.inputText = "The best way to predict the future is to invent it."
                    print("[TLKIT_DEMO] input panel visible: \(InputPanelController.shared.isVisible)")
                case "input-detailed":
                    InputPanelController.shared.showDetailed(source: "The best way to predict the future is to invent it. Simplicity is the soul of efficiency. Well begun is half done.")
                    print("[TLKIT_DEMO] detailed panel visible: \(InputPanelController.shared.isVisible)")
                case let pane where pane.hasPrefix("settings-"):
                    SettingsWindow.pendingPane = SettingsPane(rawValue: String(pane.dropFirst(9)))
                    SettingsWindow.present()
                    print("[TLKIT_DEMO] settings presented: \(String(pane.dropFirst(9)))")
                default:
                    break
                }
            }
        }
        #endif
    }

    // MARK: - 菜单栏

    /// 状态项 + 菜单。不展示快捷键标注：菜单里的 ⌘ 标注只在菜单展开时有效，全局无效，展示反而造成歧义。
    private func setupStatusItem() {
        // variableLength 与 VoiceKit 对齐（该形态在 macOS 14 实机验证过）；
        // 图标本身 18pt，实际占用宽度一致。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 水墨「译」模板图标（随深浅色自动反色）；资源缺失时退化为文字兜底。
        // K1：不走 asset catalog——Xcode 26 产出的 Assets.car 在 macOS 14 上解析失败，
        // 裸 PNG 放 bundle 里任何系统版本都能直接读。
        if let image = Self.loadMenuBarIcon() {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "译"
        }

        let menu = NSMenu()
        menu.addItem(makeItem(TLKitLocalization.string("输入翻译"), action: #selector(showInputPanel)))
        menu.addItem(makeItem(TLKitLocalization.string("翻译历史…"), action: #selector(showHistory)))
        menu.addItem(makeItem(TLKitLocalization.string("设置…"), action: #selector(showSettings)))
        menu.addItem(.separator())
        // 菜单里的退出同样走确认（与 ⌘Q 一致），高频工具防误退。
        menu.addItem(makeItem(TLKitLocalization.string("退出 TLKit"), action: #selector(confirmQuit)))
        item.menu = menu
        statusItem = item
        startStatusItemWatchdog()
    }

    // MARK: - 状态项巡检（K1）

    private var statusItemTimer: Timer?

    /// 状态项巡检（VoiceKit 在 macOS 14 实机验证过的模式）：
    /// 图标窗口被系统移除（SystemUIServer 重启等）时自动重建。
    /// 注意：macOS 14 刘海机空间不足会静默隐藏状态项（isVisible 照样为 true，
    /// 窗口被泊到屏外）——这是系统行为，重建无用、也无需对抗；
    /// 屏幕参数变化（接/拔外显）时主动重建一次，让被藏的图标有机会归位。
    private func startStatusItemWatchdog() {
        guard statusItemTimer == nil else { return }
        statusItemTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStatusItem() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func checkStatusItem() {
        guard statusItem?.button?.window != nil else {
            print("[TLKit] 状态项窗口被系统移除，重建")
            rebuildStatusItem()
            return
        }
    }

    @objc private func handleScreenChange() {
        rebuildStatusItem()
    }

    private func rebuildStatusItem() {
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }
        setupStatusItem()
    }

    /// 从 bundle 根目录加载菜单栏图标的 1x/2x/3x PNG，组合成多分辨率 NSImage。
    private static func loadMenuBarIcon() -> NSImage? {
        let image = NSImage()
        var found = false
        for name in ["menubar-18", "menubar-36", "menubar-54"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let rep = NSImageRep(contentsOf: url) {
                image.addRepresentation(rep)
                found = true
            }
        }
        guard found else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// accessory 应用窗口激活时（设置/历史）⌘Q 也走退出确认。
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(makeItem(TLKitLocalization.string("退出 TLKit"), action: #selector(confirmQuit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func showInputPanel() { InputPanelController.shared.show() }
    @objc private func showHistory() { HistoryWindow.present() }
    @objc private func showSettings() { SettingsWindow.present() }
    @objc private func confirmQuit() { QuitGuard.confirm() }
}
