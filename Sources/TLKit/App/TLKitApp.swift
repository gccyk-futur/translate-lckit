import AppKit
import SwiftUI

@main
struct TLKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // 不展示快捷键标注：菜单栏菜单里的 ⌘ 标注只在菜单展开时有效，全局无效，展示反而造成歧义。

            Button("输入翻译") {
                InputPanelController.shared.show()
            }

            Button("翻译历史…") {
                HistoryWindow.present()
            }

            Button("设置…") {
                SettingsWindow.present()
            }

            Divider()

            Button("退出 TLKit") {
                NSApp.terminate(nil)
            }
        } label: {
            // 模板渲染：自动适配深浅色与对比度（HIG）。
            Image(systemName: "character.book.closed")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // 接管 ⌘Q：退出前确认，防误退（面板内按键监听同样拦截 ⌘Q 走这里）。
            CommandGroup(replacing: .appTermination) {
                Button("退出 TLKit") { QuitGuard.confirm() }
            }
        }
    }
}

/// ⌘Q 退出确认：高频工具常驻后台，一次误按 ⌘Q 就静默退出太伤。
@MainActor
enum QuitGuard {
    static func confirm() {
        let alert = NSAlert()
        alert.messageText = "确定退出 TLKit？"
        alert.informativeText = "退出后全局快捷键与翻译面板将不可用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        // 翻译面板是 .popUpMenu 层级，确认框要再抬一级，否则被面板压在后面。
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

/// 应用代理：菜单栏 Agent（LSUIElement），启动时注册快捷键。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
