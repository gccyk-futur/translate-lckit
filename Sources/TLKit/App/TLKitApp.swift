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
    }
}

/// 应用代理：菜单栏 Agent（LSUIElement），启动时注册快捷键。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TranslationController.shared.start()
        AppearanceManager.apply()
    }
}
