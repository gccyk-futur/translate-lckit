import AppKit
import SwiftUI

/// 历史记录窗口入口（独立 NSWindow，非激活式面板——此窗口允许交互）。
@MainActor
enum HistoryWindow {
    private static var controller: NSWindowController?

    static func present() {
        if controller == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            let window = ToolWindow(contentViewController: hosting)
            window.title = TLKitLocalization.string("TLKit · 翻译历史")
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
    /// 「仅看星标」过滤：星标条目 = 词典条目。
    @State private var starredOnly = false
    /// 原地重翻失败的错误提示（alert）。
    @State private var alertMessage: String?

    private var filtered: [HistoryItem] {
        var result = history.items
        if starredOnly {
            result = result.filter(\.isStarred)
        }
        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.sourceText.localizedCaseInsensitiveContains(searchText)
                || $0.resultText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(filtered) { item in
                    HistoryRow(item: item, onRetranslate: { retranslate(item) })
                        .tag(item.id)
                }
            }
            .searchable(text: $searchText, prompt: "搜索原文或译文")
            .overlay {
                if filtered.isEmpty {
                    Text(history.items.isEmpty
                         ? TLKitLocalization.string("暂无翻译记录")
                         : TLKitLocalization.string("暂无星标记录"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let selectedID, history.items.contains(where: { $0.id == selectedID }) {
                HistoryDetail(itemID: selectedID)
            } else {
                Text(filtered.isEmpty
                     ? TLKitLocalization.string("暂无翻译记录")
                     : TLKitLocalization.string("选择一条记录查看详情"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    starredOnly.toggle()
                } label: {
                    Label("仅看星标", systemImage: starredOnly ? "star.fill" : "star")
                }
                .help(TLKitLocalization.string("仅看星标（词典条目）"))
            }
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
        .alert(
            TLKitLocalization.string("翻译失败"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("好") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func retranslate(_ item: HistoryItem) {
        // 原地重翻：就地更新记录，不跳气泡、不关窗口。
        Task {
            if let error = await HistoryRetranslator.run(item) {
                alertMessage = error
            }
        }
    }
}

/// 列表行：原文 / 译文摘要 + 星标开关 + 日期；右键菜单提供星标、重翻、删除。
/// 抽成独立视图：行内表达式嵌进 ForEach 会让类型检查超时。
private struct HistoryRow: View {
    let item: HistoryItem
    let onRetranslate: () -> Void
    @ObservedObject private var history = HistoryStore.shared

    private var starTitle: String {
        item.isStarred
            ? TLKitLocalization.string("取消星标")
            : TLKitLocalization.string("星标 · 收进词典")
    }

    var body: some View {
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
                Button {
                    history.toggleStar(id: item.id)
                } label: {
                    Image(systemName: item.isStarred ? "star.fill" : "star")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.isStarred ? Color.yellow : Color.secondary)
                .help(starTitle)
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(starTitle) { history.toggleStar(id: item.id) }
            Button("重新翻译", action: onRetranslate)
            Button("删除", role: .destructive, action: { history.remove(id: item.id) })
        }
    }
}

/// 详情区：原文、译文、操作按钮；星标条目附带词典解读区。
/// 按 id 实时回查 Store：星标/解读变更能立即反映到界面。
private struct HistoryDetail: View {
    let itemID: UUID
    @ObservedObject private var history = HistoryStore.shared
    @State private var generating = false
    @State private var interpretError: String?
    @State private var retranslating = false
    @State private var retranslateError: String?

    private var item: HistoryItem? {
        history.items.first { $0.id == itemID }
    }

    var body: some View {
        if let item {
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

                if item.isStarred {
                    dictionarySection(item)
                }

                Spacer()

                if let retranslateError {
                    Text(retranslateError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text("\(item.service) · \(item.date.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        history.toggleStar(id: item.id)
                    } label: {
                        Label(item.isStarred
                              ? TLKitLocalization.string("取消星标")
                              : TLKitLocalization.string("星标 · 收进词典"),
                              systemImage: item.isStarred ? "star.fill" : "star")
                    }
                    .controlSize(.small)
                    Button {
                        retranslate(item)
                    } label: {
                        Label(retranslating
                              ? TLKitLocalization.string("翻译中…")
                              : TLKitLocalization.string("重新翻译"),
                              systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(retranslating)
                }
            }
            .padding(16)
        }
    }

    /// 词典解读区：星标条目专属。
    /// 生成按钮按「已配置完整」的 AI 引擎逐个给出（配置过即能用，与当前激活引擎无关）；
    /// 系统翻译 / 百度不能吃提示词，永远不在清单里。
    @ViewBuilder
    private func dictionarySection(_ item: HistoryItem) -> some View {
        let engines = DictionaryInterpreter.configuredEngines
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("词典解读")
                Spacer()
                if item.interpretation != nil {
                    Button {
                        SpeechManager.shared.toggle(
                            text: item.interpretation ?? "",
                            language: TranslationController.detectLanguage(from: item.interpretation ?? "")
                        )
                    } label: {
                        Label("朗读解读", systemImage: "speaker.wave.2")
                    }
                    .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if generating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成解读…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let interpretation = item.interpretation {
                Text(interpretation)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if engines.isEmpty {
                Text("生成解读需要 AI 大模型或 Ollama 引擎，请先在「设置 → 翻译引擎」中完成配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("点击「生成解读」，为这个条目生成音标、释义与例句。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !engines.isEmpty {
                HStack(spacing: 8) {
                    ForEach(engines, id: \.rawValue) { kind in
                        Button {
                            generateInterpretation(item, using: kind)
                        } label: {
                            Label(
                                TLKitLocalization.format(
                                    item.interpretation == nil
                                        ? TLKitLocalization.string("生成解读（%@）")
                                        : TLKitLocalization.string("重新生成（%@）"),
                                    DictionaryInterpreter.engineLabel(kind)
                                ),
                                systemImage: "sparkles"
                            )
                        }
                        .controlSize(.small)
                        .disabled(generating)
                    }
                }
            }

            if let interpretError {
                Text(interpretError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.08)))
    }

    private func generateInterpretation(_ item: HistoryItem, using kind: ServiceKind) {
        generating = true
        interpretError = nil
        Task {
            do {
                let text = try await DictionaryInterpreter.generate(for: item, using: kind)
                HistoryStore.shared.setInterpretation(id: item.id, text: text)
            } catch {
                interpretError = error.localizedDescription
            }
            generating = false
        }
    }

    /// 原地重翻：就地更新记录（译文与引擎随行更新），不跳气泡、不关窗口。
    private func retranslate(_ item: HistoryItem) {
        retranslating = true
        retranslateError = nil
        Task {
            let error = await HistoryRetranslator.run(item)
            retranslateError = error
            retranslating = false
        }
    }
}

@MainActor
extension HistoryWindow {
    static func close() {
        controller?.window?.close()
    }
}
