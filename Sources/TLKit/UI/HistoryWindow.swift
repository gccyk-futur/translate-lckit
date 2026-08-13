import AppKit
import SwiftUI

/// 历史记录窗口入口（独立 NSWindow，非激活式面板——此窗口允许交互）。
@MainActor
enum HistoryWindow {
    private static var controller: NSWindowController?

    static func present() {
        if controller == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "TLKit · 翻译历史"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 760, height: 480))
            window.minSize = NSSize(width: 560, height: 320)
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

/// 历史列表 + 详情双栏视图。
struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        guard !searchText.isEmpty else { return history.items }
        return history.items.filter {
            $0.sourceText.localizedCaseInsensitiveContains(searchText)
                || $0.resultText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.sourceText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            Text(item.resultText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                    .contextMenu {
                        Button("重新翻译", action: { retranslate(item) })
                        Button("删除", role: .destructive, action: { history.remove(id: item.id) })
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索原文或译文")
            .overlay {
                if history.items.isEmpty {
                    Text("暂无翻译记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let item = history.items.first(where: { $0.id == selectedID }) {
                HistoryDetail(item: item)
            } else {
                Text(filtered.isEmpty ? "暂无翻译记录" : "选择一条记录查看详情")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("清空全部", systemImage: "trash")
                }
                .disabled(history.items.isEmpty)
            }
        }
        .confirmationDialog(
            "确定清空全部历史记录？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空全部", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    private func retranslate(_ item: HistoryItem) {
        HistoryWindow.close()
        TranslationController.shared.translateText(item.sourceText)
    }
}

/// 详情区：原文、译文、操作按钮。
private struct HistoryDetail: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("原文")
                    Spacer()
                    Button {
                        SpeechManager.shared.toggle(
                            text: item.sourceText,
                            language: TranslationController.detectLanguage(from: item.sourceText)
                        )
                    } label: {
                        Label("朗读原文", systemImage: "speaker.wave.2")
                    }
                    .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(item.sourceText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("译文")
                    Spacer()
                    Button {
                        SpeechManager.shared.toggle(text: item.resultText, language: item.targetLang)
                    } label: {
                        Label("朗读译文", systemImage: "speaker.wave.2")
                    }
                    .controlSize(.small)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.resultText, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(item.resultText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))

            Spacer()

            HStack(spacing: 12) {
                Text("\(item.service) · \(item.date.formatted(date: .numeric, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    HistoryWindow.close()
                    TranslationController.shared.translateText(item.sourceText)
                } label: {
                    Label("重新翻译", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

@MainActor
extension HistoryWindow {
    static func close() {
        controller?.window?.close()
    }
}
