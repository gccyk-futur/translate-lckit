import AppKit

/// 通道 A：模拟 ⌘C + 剪贴板读取（直装版默认）。
///
/// 流程：备份剪贴板 → 模拟 ⌘C → 轮询 changeCount（上限 1 秒）→ 读文本 → 还原剪贴板。
/// 需要辅助功能权限（CGEvent 投递的系统要求）。
@MainActor
final class ClipboardSelectionReader: SelectionReader {

    func readSelection() async -> String? {
        let pb = NSPasteboard.general
        let backup = Self.backup(of: pb)
        let before = pb.changeCount

        postCopy()

        // 轮询等待剪贴板变化，上限 1 秒。
        let deadline = Date().addingTimeInterval(1.0)
        while pb.changeCount == before, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let text: String? = pb.changeCount != before ? pb.string(forType: .string) : nil

        // 给源应用一点时间完成写入，再还原。
        try? await Task.sleep(for: .milliseconds(120))
        Self.restore(backup, to: pb)

        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : text
    }

    // MARK: - 模拟 ⌘C

    private func postCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let kVK_ANSI_C: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_C, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 剪贴板备份 / 还原

    private struct SavedItem {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private static func backup(of pb: NSPasteboard) -> [SavedItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            SavedItem(entries: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
    }

    private static func restore(_ saved: [SavedItem], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { savedItem in
            let item = NSPasteboardItem()
            var entries = savedItem.entries
            // 文件 URL 优先以 URL 语义写回，保证 Finder 场景可用。
            if let idx = entries.firstIndex(where: { $0.type == .fileURL }),
               let url = URL(dataRepresentation: entries[idx].data, relativeTo: nil) {
                entries.remove(at: idx)
                item.setString(url.absoluteString, forType: .fileURL)
            }
            for entry in entries where entry.type != .fileURL {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        pb.writeObjects(items)
    }
}
