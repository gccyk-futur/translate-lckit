import AppKit

// 纯 AppKit 生命周期入口。
// 为什么不用 SwiftUI App + MenuBarExtra：MenuBarExtra 在 macOS 14 上菜单栏图标
// 渲染失败（进程活着、热键可用、状态栏窗口已创建但图标不可见，K1 实测）。
// 换回 OS X 时代就稳定的 NSStatusItem；窗口层全部是 NSHostingController 宿主，
// 不依赖任何 SwiftUI Scene。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
