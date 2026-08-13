import SwiftUI

/// 气泡状态机。
enum BubbleState {
    case loading(source: String)
    case result(source: String, translation: String, service: String, truncated: Bool)
    case error(message: String)
    case noSelection
    case permissionNeeded
}

/// 气泡内容视图（挂在 NSPanel 的 NSHostingView 中）。
///
/// HIG：语义色（.primary/.secondary/.tertiary）随深浅色自动适配；
/// 8pt 间距栅格；结果卡片用 hairline 分隔原文与译文；图标按钮带
/// ~28pt 命中区与 VoiceOver 提示。
struct BubbleView: View {
    let state: BubbleState
    var onOpenAccessibility: () -> Void = {}
    /// 朗读原文回调（参数为原文文本）。
    var onSpeak: ((String) -> Void)?
    /// 「详细」回调：把原文送进翻译面板的逐句对照模式。
    var onOpenDetailed: ((String) -> Void)?

    @State private var speechRate: Float = ConfigStore.shared.current.tts.speechRate
    @State private var showSpeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: TLStyle.space2) {
            content
        }
        .padding(.horizontal, TLStyle.space3)
        .padding(.top, 10)
        .padding(.bottom, TLStyle.space3)
        .frame(width: TLStyle.bubbleWidth, alignment: .leading)
        // 面板复用：每次展示时同步最新语速（可能在设置或其他气泡中改过）。
        .onAppear { speechRate = ConfigStore.shared.current.tts.speechRate }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading(let source):
            HStack(spacing: TLStyle.space2) {
                ProgressView().controlSize(.small)
                Text("翻译中…")
                    .font(TLStyle.control)
                    .foregroundStyle(.secondary)
            }
            sourceLine(source)

        case .result(let source, let translation, let service, let truncated):
            VStack(alignment: .leading, spacing: TLStyle.space2) {
                // 原文：次要层级，小字摘录
                Text(truncated ? source + " …（已截断）" : source)
                    .font(TLStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)

                Divider()

                // 译文：主体层级
                ScrollView {
                    Text(translation)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                HStack(spacing: TLStyle.space1) {
                    Text("TLKit × \(service)")
                        .font(TLStyle.footnote)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    iconButton(systemName: "list.bullet.below.rectangle",
                               label: "详细对照",
                               hint: "打开翻译面板，逐句对照原文与译文") { onOpenDetailed?(source) }
                    iconButton(systemName: "speedometer",
                               label: "朗读速度",
                               hint: "展开或收起朗读速度调节条") { showSpeed.toggle() }
                    iconButton(systemName: "speaker.wave.2",
                               label: "朗读原文",
                               hint: "朗读翻译前的原文") { onSpeak?(source) }
                    iconButton(systemName: "doc.on.doc",
                               label: "复制译文",
                               hint: "将译文拷贝到剪贴板") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation, forType: .string)
                    }
                }

                // 语速调节：按需展开，不占用主布局
                if showSpeed {
                    HStack(spacing: TLStyle.space2) {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Slider(value: $speechRate, in: 0.5...2.0, step: 0.1)
                            .controlSize(.small)
                            .help("拖动调整朗读速度")
                        Image(systemName: "hare.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(String(format: "%.1fx", speechRate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .onChange(of: speechRate) { _, newValue in
                        ConfigStore.shared.update { $0.tts.speechRate = newValue }
                    }
                }
            }

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(TLStyle.control)
                .foregroundStyle(.red)

        case .noSelection:
            Text("未检测到选中的文字")
                .font(TLStyle.control)
                .foregroundStyle(.secondary)

        case .permissionNeeded:
            VStack(alignment: .leading, spacing: TLStyle.space2) {
                Label("需要辅助功能权限", systemImage: "hand.raised")
                    .font(TLStyle.control)
                Text("请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 TLKit，然后重试。")
                    .font(TLStyle.caption)
                    .foregroundStyle(.secondary)
                Button("打开系统设置") { onOpenAccessibility() }
                    .controlSize(.small)
            }
        }
    }

    /// 统一图标按钮：~28pt 命中区 + VoiceOver 标签与提示。
    private func iconButton(
        systemName: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .imageScale(.medium)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func sourceLine(_ text: String) -> some View {
        Text(text)
            .font(TLStyle.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
