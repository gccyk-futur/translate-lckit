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
    /// 错误态「翻译设置…」回调。
    var onOpenSettings: (() -> Void)?
    /// 权限态「不再提醒」回调。
    var onNeverRemindPermission: (() -> Void)?

    @State private var speechRate: Float = ConfigStore.shared.current.tts.speechRate
    @State private var showSpeed = false
    @State private var hintsSuppressed = ConfigStore.shared.current.suppressBubbleHints

    var body: some View {
        VStack(alignment: .leading, spacing: TLStyle.space2) {
            content
        }
        .padding(.horizontal, TLStyle.space3)
        .padding(.top, TLStyle.space5)
        .padding(.bottom, TLStyle.space3)
        .frame(width: TLStyle.bubbleWidth, alignment: .leading)
        // 面板标题栏隐藏但 SwiftUI 仍预留其安全区（造成上部大空白），这里拿掉。
        .ignoresSafeArea()
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
            // 即时反馈阶段（取词中）source 为空，不渲染空行。
            if !source.isEmpty {
                sourceLine(source)
            }

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
                               label: "朗读原文（空格）",
                               hint: "朗读翻译前的原文，快捷键空格") { onSpeak?(source) }
                    iconButton(systemName: "doc.on.doc",
                               label: "复制译文",
                               hint: "将译文拷贝到剪贴板") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation, forType: .string)
                    }
                }

                // 快捷键小提示：居中胶囊 tag，「不再提示」仅指这条提示本身。
                if !hintsSuppressed {
                    HStack(spacing: 6) {
                        Text("空格 朗读 · Esc 关闭")
                            .foregroundStyle(.tertiary)
                        Button("不再提示") {
                            hintsSuppressed = true
                            ConfigStore.shared.update { $0.suppressBubbleHints = true }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .help("不再显示这条快捷键提示")
                    }
                    .font(TLStyle.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .center)
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
            // 柔和错误态：橙标 + 次级文字，不刺眼；附设置引导，失败不再死胡同。
            VStack(alignment: .leading, spacing: TLStyle.space2) {
                Label {
                    Text(message)
                        .font(TLStyle.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("翻译设置…") { onOpenSettings?() }
                    .controlSize(.small)
            }

        case .noSelection:
            Text("未检测到选中的文字")
                .font(TLStyle.control)
                .foregroundStyle(.secondary)

        case .permissionNeeded:
            // 可选项口吻：授权才开划词；不授权退化为输入面板，不是「必须授权」。
            VStack(alignment: .leading, spacing: TLStyle.space2) {
                Label("想要划词翻译？", systemImage: "hand.raised")
                    .font(TLStyle.control)
                Text("辅助功能权限仅用于读取你选中的文字（模拟 ⌘C），内容不离开本机。")
                    .font(TLStyle.caption)
                    .foregroundStyle(.secondary)
                Text("不授权也不影响使用：按快捷键会直接打开输入翻译面板。")
                    .font(TLStyle.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: TLStyle.space2) {
                    Button("去授权") { onOpenAccessibility() }
                        .controlSize(.small)
                    // 记住选择：之后快捷键直开输入面板，不再出现本提示。
                    Button("不了，直接输入翻译") { onNeverRemindPermission?() }
                        .controlSize(.small)
                }
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
