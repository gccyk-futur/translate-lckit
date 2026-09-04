import AppKit
import Carbon.HIToolbox

/// 全局热键管理：Carbon RegisterEventHotKey，支持多条目同时注册。
///
/// Carbon 热键在沙盒内可用且零权限（实测验证），App Store 版无需回退方案。
/// 每个条目以调用方给的 key 标识（翻译目标清单的条目 ID），触发时回调携带 key。
@MainActor
final class HotkeyManager {
    private struct Registration {
        let ref: EventHotKeyRef
        let key: String
        let shortcut: Shortcut
    }

    /// hotKeyID → 注册信息。
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x544C4B54 // 'TLKT'
    private var nextHotKeyID: UInt32 = 1

    /// 热键触发回调（主线程）；参数为注册时的条目 key。
    var onActivate: ((String) -> Void)?

    /// 全量重注册：先注销全部，再按顺序注册。
    /// 空快捷键跳过；多个条目撞同一快捷键时先注册者生效，后者记日志跳过。
    func registerAll(_ entries: [(key: String, shortcut: Shortcut)]) {
        unregisterAll()
        var seen: Set<Shortcut> = []
        for entry in entries {
            let shortcut = entry.shortcut
            guard !shortcut.isEmpty else { continue }
            guard seen.insert(shortcut).inserted else {
                print("[TLKit] 热键冲突，跳过重复注册：\(shortcut.displayString)")
                continue
            }
            installCarbonHandler()
            let id = nextHotKeyID
            nextHotKeyID += 1
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers,
                hotKeyID, GetApplicationEventTarget(), 0, &ref
            )
            if status != noErr || ref == nil {
                print("[TLKit] 热键注册失败 status=\(status)：\(shortcut.displayString)")
            } else {
                print("[TLKit] 热键注册成功：\(shortcut.displayString)")
                registrations[id] = Registration(ref: ref!, key: entry.key, shortcut: shortcut)
            }
        }
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
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

    fileprivate func handleHotkeyEvent(id: UInt32) {
        guard let key = registrations[id]?.key else { return }
        onActivate?(key)
    }
}

/// Carbon 事件回调（主线程事件循环投递）。
private func tlkitHotkeyCallback(
    _ handler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    // 从事件参数取出 hotKeyID，据此分发给对应条目。
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleHotkeyEvent(id: hotKeyID.id)
    }
    return noErr
}
