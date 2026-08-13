import AppKit
import Carbon.HIToolbox

/// 全局热键管理：Carbon RegisterEventHotKey。
///
/// Carbon 热键在沙盒内可用且零权限（实测验证），App Store 版无需回退方案。
/// 支持注册 / 注销 / 自定义变更（重复调用 register 会先注销旧热键）。
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x544C4B54 // 'TLKT'
    private let hotKeyIDValue: UInt32 = 1

    /// 热键触发回调（主线程）。
    var onActivate: (() -> Void)?

    func register(shortcut: Shortcut) {
        unregister()
        guard !shortcut.isEmpty else { return }
        installCarbonHandler()
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if status != noErr {
            print("[TLKit] 热键注册失败 status=\(status)：\(shortcut.displayString)")
        } else {
            print("[TLKit] 热键注册成功：\(shortcut.displayString)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Carbon 事件处理

    private func installCarbonHandler() {
        guard eventHandler == nil else { return }
        var types = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            tlkitHotkeyCallback,
            1,
            &types,
            selfPtr,
            &eventHandler
        )
    }

    fileprivate func handleHotkeyEvent() {
        onActivate?()
    }
}

/// Carbon 事件回调（主线程事件循环投递）。
private func tlkitHotkeyCallback(
    _ handler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleHotkeyEvent()
    }
    return noErr
}
