import AppKit
import SwiftUI

/// 翻译面板展示模式：简洁 = 双栏实时翻译；详细 = 大面板逐句对照。
enum PanelMode: Hashable {
    case simple
    case detailed
}

/// 逐句对照条目（详细模式）。
struct SentencePair: Identifiable, Equatable {
    let id: Int
    let source: String
    var translation: String?
}

/// 输入翻译面板控制器：居中浮窗，无选中文字时触发。
///
/// 浮窗配方：
/// - NSPanel(.nonactivatingPanel) 不抢前应用焦点
/// - NSVisualEffectView(.popover) 毛玻璃
/// - Esc 关闭、⌘+Enter 翻译
/// - 屏幕居中
@MainActor
final class InputPanelController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = InputPanelController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<InputPanelView>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// 面板弹出前的前台应用；关闭时归还焦点。
    private var previousApp: NSRunningApplication?

    @Published var inputText = ""
    @Published var resultText = ""
    /// 目标语言：跟随配置初始化；用户改动后写回配置，重启后保留。
    @Published var targetLanguage: String = ConfigStore.shared.current.panelTargetLanguage {
        didSet {
            guard targetLanguage != oldValue else { return }
            ConfigStore.shared.update { $0.panelTargetLanguage = targetLanguage }
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 当前输入的检测语言（NaturalLanguage，离线）；空输入为 nil。
    var detectedSourceCode: String? {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : LanguageCatalog.detect(text)
    }

    /// 源语言展示名：检测到则显示语言名，否则「自动检测」。
    var sourceDisplayLabel: String {
        detectedSourceCode.map { LanguageCatalog.name(for: $0) } ?? "自动检测"
    }

    /// 展示模式；切换时窗口尺寸随之变化（同窗口内切换）。
    @Published var mode: PanelMode = .simple {
        didSet {
            guard oldValue != mode else { return }
            applyFrame(animated: true)
            if mode == .detailed { translateDetailed() }
        }
    }
    /// 逐句对照数据（详细模式）。
    @Published var pairs: [SentencePair] = []
    /// 当前悬停的句子（高亮对应原文/译文）。
    @Published var hoveredPairId: Int?

    private var translateTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var detailedTask: Task<Void, Never>?

    /// 每次 show 递增，视图据此重新聚焦输入框。
    @Published var focusToken = 0

    var serviceName: String {
        (try? ServiceFactory.makeActive().displayName) ?? "—"
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 预热：启动时建好面板与 SwiftUI 视图，首次呼出免构建开销。
    func prewarm() {
        if panel == nil { buildPanel() }
    }

    // MARK: - 展示 / 关闭

    /// 快捷键无选中时：弹简洁模式面板。
    func show() {
        translateTask?.cancel()
        detailedTask?.cancel()
        // 草稿语义：主动关闭（Esc / ⌘W / 红色关闭键 / 快捷键 toggle）会清空内容，
        // 只有失焦（可能误触）关闭才保留现场；此处不再做任何重置。
        errorMessage = nil
        isLoading = false
        pairs = []
        mode = .simple
        focusToken += 1
        present()
    }

    /// 气泡「详细」入口：带指定原文弹详细模式，逐句对照翻译。
    func showDetailed(source: String) {
        translateTask?.cancel()
        detailedTask?.cancel()
        inputText = source
        resultText = ""
        errorMessage = nil
        isLoading = false
        focusToken += 1
        mode = .detailed
        present()
    }

    private func present() {
        if panel == nil { buildPanel() }
        // 失焦即关：TLKit 让出活跃状态（点击/⌘Tab 到其他应用）即关闭面板。
        // dismiss 内的焦点归还逻辑会自检前台应用，不会把焦点抢回来。
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    // 失焦被动关闭：保留现场，避免误触丢稿。
                    self.dismiss(clearDraft: false)
                }
            }
        }
        // 激活 TLKit：外部输入工具（语音输入、输入法等）只会把文本送给活跃应用，
        // 不激活则面板拿不到它们的输出；关闭时归还焦点给原前台应用。
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel?.center()
        applyFrame(animated: false)
        panel?.orderFrontRegardless()
        panel?.makeKey()
        installKeyMonitor()
    }

    /// 关闭面板。
    /// - Parameter clearDraft: 主动关闭（Esc / ⌘W / 红色关闭键 / 快捷键 toggle）传 true 清空内容；
    ///   失焦被动关闭传 false 保留现场，避免误触丢稿。
    func dismiss(clearDraft: Bool = true) {
        translateTask?.cancel()
        detailedTask?.cancel()
        removeKeyMonitor()
        SpeechManager.shared.stop()
        panel?.orderOut(nil)
        if clearDraft { clearInput() }
        // 归还焦点：仅当期间用户没有自己切走（前台仍是 TLKit）时才归还。
        if let previousApp,
           NSWorkspace.shared.frontmostApplication?.processIdentifier
               == NSRunningApplication.current.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - 翻译

    func translate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        debounceTask?.cancel()
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            self.errorMessage = nil

            let target = self.targetLanguage
            let truncated = text.count > 3000
            let sourceText = String(text.prefix(3000))

            do {
                let service = try ServiceFactory.makeActive()
                let translation = try await service.translate(sourceText, to: target)
                guard !Task.isCancelled else { return }
                self.resultText = translation
                self.isLoading = false

                HistoryStore.shared.appendDedup(HistoryItem(
                    sourceText: truncated ? sourceText + " …（已截断）" : sourceText,
                    resultText: translation,
                    targetLang: target,
                    service: service.displayName
                ))
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    // MARK: - 面板操作

    /// 「⇄」交换（Google 翻译式）：译文变原文重新翻译，目标语言换成原输入的检测语言。
    /// 无译文或源语言与目标相同时不可用。
    func swapLanguages() {
        guard !resultText.isEmpty, let source = detectedSourceCode, source != targetLanguage else { return }
        inputText = resultText
        resultText = ""
        targetLanguage = source
        // 视图的 onChange(inputText) 会自动调度实时翻译。
    }

    func clearInput() {
        translateTask?.cancel()
        debounceTask?.cancel()
        detailedTask?.cancel()
        inputText = ""
        resultText = ""
        errorMessage = nil
        pairs = []
    }

    func copyResult() {
        guard !resultText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
    }

    /// 输入停顿 0.6s 后自动翻译（实时翻译）；⌘Enter 可立即触发。
    func scheduleAutoTranslate() {
        debounceTask?.cancel()
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resultText = ""
            errorMessage = nil
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.translate()
        }
    }

    // MARK: - 详细模式（逐句对照）

    /// 拆句后并发翻译（最多 4 路），逐句回填 pairs。
    func translateDetailed() {
        detailedTask?.cancel()
        hoveredPairId = nil
        errorMessage = nil
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            pairs = []
            return
        }
        let sentences = Self.splitSentences(text)
        pairs = sentences.enumerated().map { SentencePair(id: $0.offset, source: $0.element) }

        detailedTask = Task { [weak self] in
            guard let self else { return }
            let service: TranslationService
            do {
                service = try ServiceFactory.makeActive()
            } catch {
                self.errorMessage = error.localizedDescription
                return
            }
            let target = self.targetLanguage
            let count = sentences.count
            await withTaskGroup(of: (Int, String?).self) { group in
                var submitted = 0
                var inFlight = 0
                while submitted < count || inFlight > 0 {
                    while inFlight < 4, submitted < count {
                        let index = submitted
                        group.addTask {
                            (index, try? await service.translate(sentences[index], to: target))
                        }
                        submitted += 1
                        inFlight += 1
                    }
                    guard let (index, translated) = await group.next() else { break }
                    inFlight -= 1
                    if Task.isCancelled {
                        group.cancelAll()
                        return
                    }
                    if index < self.pairs.count {
                        self.pairs[index].translation = translated
                    }
                }
            }
        }
    }

    /// 拆句：CJK 标点/叹问号直接切；拉丁句号等仅在后随空白或结尾时切
    /// （避免切断小数与缩写）。超出上限时整段作一条。
    static func splitSentences(_ text: String, maxCount: Int = 40) -> [String] {
        let hardTerminators: Set<Character> = ["。", "！", "？", "!", "?", "…", "\n"]
        let softTerminators: Set<Character> = [".", ";", "；"]
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }

        for (index, char) in chars.enumerated() {
            current.append(char)
            if hardTerminators.contains(char) {
                flush()
            } else if softTerminators.contains(char) {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if next == nil || next!.isWhitespace { flush() }
            }
        }
        flush()

        if sentences.count > maxCount { return [text] }
        return sentences
    }

    /// 按模式调整窗口尺寸（保持中心不变）。
    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let size = mode == .simple
            ? NSSize(width: TLStyle.inputWidth, height: 268)
            : NSSize(width: TLStyle.detailedWidth, height: TLStyle.detailedHeight)
        var frame = panel.frame
        frame.origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        frame.size = size
        panel.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - 构建

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(TLStyle.inputWidth), height: 268),
            // .closable：提供红色关闭按钮（高频浮窗的可见出口）；黄/绿对浮窗无意义，隐藏。
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = TLStyle.cornerRadius
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: InputPanelView(controller: self))
        // 隐藏标题栏仍会向 SwiftUI 下发安全区，关掉后语言栏才能上提到关闭键同一水平线。
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // 毛玻璃铺满窗口 contentView（fullSizeContentView 下含透明标题栏区域），
        // 内容贴窗口顶开始排布，避免标题栏把 contentView 下挤造成大上边距。
        effect.translatesAutoresizingMaskIntoConstraints = false
        if let root = panel.contentView {
            root.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                effect.topAnchor.constraint(equalTo: root.topAnchor),
                effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        self.panel = panel
        self.hosting = hosting
    }

    // MARK: - 键盘（⌘+Enter 翻译 / Esc 关闭）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent 不可跨隔离传递（非 Sendable），先拆出原始值再进 MainActor 闭包。
            let keyCode = event.keyCode
            let mods = Shortcut.carbonModifiers(
                from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            let cmd = mods & 0x100 != 0
            let handled: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                let config = ConfigStore.shared.current
                // ⌘+Enter 翻译
                if cmd, keyCode == 36 { self.translate(); return true }
                // 朗读（默认 ⌘R，可在设置中改）
                if config.panelSpeakHotkey.matches(keyCode: keyCode, carbonModifiers: mods) {
                    self.speakPreferred(); return true
                }
                // 清空输入（默认 ⌘K，可在设置中改）
                if config.panelClearHotkey.matches(keyCode: keyCode, carbonModifiers: mods) {
                    self.clearInput(); return true
                }
                // ⌘1 简洁模式 / ⌘2 详细模式
                if cmd, keyCode == 18 { self.mode = .simple; return true }
                if cmd, keyCode == 19 { self.mode = .detailed; return true }
                // Esc / ⌘W 关闭
                if keyCode == 53 || (cmd && keyCode == 13) { self.dismiss(); return true }
                // ⌘Q 退出前确认，防误退
                if cmd, keyCode == 12 { QuitGuard.confirm(); return true }
                return false
            }
            return handled ? nil : event
        }
    }

    /// ⌘R 朗读：译文优先，无译文时读原文。
    private func speakPreferred() {
        if !resultText.isEmpty {
            SpeechManager.shared.toggle(text: resultText, language: targetLanguage)
        } else if let source = detectedSourceCode {
            SpeechManager.shared.toggle(text: inputText, language: source)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// 点击红色关闭按钮 = Esc 关闭（走统一 dismiss：清理监听、停止朗读、归还焦点）。
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { self.dismiss() }
        return false
    }

}

/// 输入翻译面板内容视图：类 Google 翻译的左右双栏（左原文、右译文），
/// 顶栏语言方向 + 交换按钮，输入停顿自动实时翻译。
struct InputPanelView: View {
    @ObservedObject var controller: InputPanelController

    @State private var speechRate: Float = ConfigStore.shared.current.tts.speechRate
    @State private var showSpeed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.mode == .simple {
                HStack(spacing: TLStyle.space2) {
                    sourceColumn
                    targetColumn
                }
                .padding(.horizontal, TLStyle.space3)
            } else {
                detailedColumn
                    .padding(.horizontal, TLStyle.space3)
            }
            footer
        }
        .frame(width: controller.mode == .simple ? TLStyle.inputWidth : TLStyle.detailedWidth,
               height: controller.mode == .simple ? 268 : TLStyle.detailedHeight)
        .onAppear { speechRate = ConfigStore.shared.current.tts.speechRate }
        .onChange(of: controller.inputText) { _, _ in
            controller.scheduleAutoTranslate()
        }
    }

    // MARK: 顶栏（语言方向 + 简洁/详细切换）

    private var header: some View {
        HStack(spacing: TLStyle.space2) {
            languageBar
            Picker("展示模式", selection: $controller.mode) {
                Text("简洁").tag(PanelMode.simple)
                Text("详细").tag(PanelMode.detailed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            .help("切换展示模式：简洁为双栏实时翻译，详细为逐句对照（⌘1 / ⌘2）")
            .accessibilityLabel("展示模式")
        }
        // 上提到与左上角红色关闭键同一水平线，消除标题栏死空间；左侧让位关闭键。
        .padding(.leading, 52)
        .padding(.trailing, TLStyle.space3)
        .padding(.top, TLStyle.space3)
        .padding(.bottom, 10)
    }

    private var languageBar: some View {
        HStack(spacing: 0) {
            // 源语言始终自动检测，翻译后显示检测结果。
            Text(controller.sourceDisplayLabel)
                .font(TLStyle.label)
                .foregroundStyle(controller.detectedSourceCode == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity)
            Button {
                controller.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(TLStyle.control)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, TLStyle.space2)
            .disabled(controller.resultText.isEmpty)
            .help("交换：译文变原文，目标语言换成原文语言")
            .accessibilityLabel("交换语言")
            // 目标语言下拉（面板内改动会持久化）。
            Picker("目标语言", selection: $controller.targetLanguage) {
                ForEach(LanguageCatalog.all, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("目标语言")
        }
    }

    // MARK: 左栏（原文输入）

    private var sourceColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PlainTextView(text: $controller.inputText, focusToken: controller.focusToken)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if controller.inputText.isEmpty {
                    Text("输入要翻译的文字")
                        .font(TLStyle.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button {
                    SpeechManager.shared.toggle(
                        text: controller.inputText,
                        language: controller.detectedSourceCode ?? "en"
                    )
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("朗读原文")
                .accessibilityLabel("朗读原文")

                Spacer()

                // 常驻显示（空内容置灰）：清空入口要看得见，不用记住快捷键才发现。
                Button {
                    controller.clearInput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .disabled(controller.inputText.isEmpty && controller.resultText.isEmpty)
                .help("清空输入（\(ConfigStore.shared.current.panelClearHotkey.displayString)）")
                .accessibilityLabel("清空输入")
            }
            .font(TLStyle.control)
            .padding(.horizontal, TLStyle.space2)
            .padding(.bottom, TLStyle.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: TLStyle.innerRadius))
    }

    // MARK: 右栏（译文结果）

    private var targetColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if let error = controller.errorMessage {
                        // 柔和错误态：橙标 + 次级文字，附设置引导。
                        VStack(alignment: .leading, spacing: TLStyle.space2) {
                            Label {
                                Text(error)
                                    .font(TLStyle.caption)
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Button("翻译设置…") { SettingsWindow.present() }
                                .controlSize(.small)
                        }
                    } else if controller.resultText.isEmpty {
                        Text("翻译")
                            .font(TLStyle.body)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(controller.resultText)
                            .font(TLStyle.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
            HStack {
                Button {
                    controller.copyResult()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(controller.resultText.isEmpty)
                .help("复制译文")
                .accessibilityLabel("复制译文")

                Button {
                    SpeechManager.shared.toggle(
                        text: controller.resultText,
                        language: controller.targetLanguage
                    )
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(controller.resultText.isEmpty)
                .help("朗读译文（\(ConfigStore.shared.current.panelSpeakHotkey.displayString)）")
                .accessibilityLabel("朗读译文")

                Button {
                    showSpeed.toggle()
                } label: {
                    Image(systemName: "speedometer")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(controller.resultText.isEmpty)
                .help("朗读速度")
                .accessibilityLabel("朗读速度")

                Spacer()

                if controller.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .font(TLStyle.control)
            .padding(.horizontal, TLStyle.space2)
            .padding(.bottom, TLStyle.space1)

            // 语速调节：按需展开，与气泡同一套交互。
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
                .padding(.horizontal, TLStyle.space2)
                .padding(.bottom, TLStyle.space1)
                .onChange(of: speechRate) { _, newValue in
                    ConfigStore.shared.update { $0.tts.speechRate = newValue }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: TLStyle.innerRadius))
    }

    // MARK: 详细模式（逐句对照，悬停高亮对应句）

    private var detailedColumn: some View {
        Group {
            if let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: TLStyle.space2) {
                    Label {
                        Text(error)
                            .font(TLStyle.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button("翻译设置…") { SettingsWindow.present() }
                        .controlSize(.small)
                }
                .padding(TLStyle.space2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if controller.pairs.isEmpty {
                Text("输入文字后切到「详细」，逐句对照翻译")
                    .font(TLStyle.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: TLStyle.space2) {
                        ForEach(controller.pairs) { pair in
                            sentenceRow(pair)
                        }
                    }
                    .padding(.vertical, TLStyle.space2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: TLStyle.innerRadius))
    }

    /// 单句对照行：原文在上（次要层级）、译文在下；悬停时整行高亮，
    /// 以此建立译文 ↔ 原文的映射标识。
    private func sentenceRow(_ pair: SentencePair) -> some View {
        let hovered = controller.hoveredPairId == pair.id
        return VStack(alignment: .leading, spacing: TLStyle.space1) {
            Text(pair.source)
                .font(TLStyle.caption)
                .foregroundStyle(.secondary)
            if let translation = pair.translation {
                Text(translation)
                    .font(TLStyle.body)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: TLStyle.space1) {
                    ProgressView().controlSize(.mini)
                    Text("翻译中…")
                        .font(TLStyle.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TLStyle.space2)
        .background(Color.accentColor.opacity(hovered ? 0.12 : 0),
                    in: RoundedRectangle(cornerRadius: TLStyle.innerRadius))
        .overlay(alignment: .topTrailing) {
            if hovered { sentenceToolbar(pair) }
        }
        .onHover { inside in
            controller.hoveredPairId = inside
                ? pair.id
                : (controller.hoveredPairId == pair.id ? nil : controller.hoveredPairId)
        }
    }

    /// 悬停时出现的句子工具条：读原文 / 读译文 / 复制译文。
    private func sentenceToolbar(_ pair: SentencePair) -> some View {
        HStack(spacing: TLStyle.space1) {
            Button {
                SpeechManager.shared.toggle(text: pair.source,
                                            language: controller.detectedSourceCode ?? "en")
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .help("朗读这句原文")
            .accessibilityLabel("朗读这句原文")

            Button {
                if let translation = pair.translation {
                    SpeechManager.shared.toggle(text: translation,
                                                language: controller.targetLanguage)
                }
            } label: {
                Image(systemName: "waveform")
            }
            .disabled(pair.translation == nil)
            .help("朗读这句译文")
            .accessibilityLabel("朗读这句译文")

            Button {
                if let translation = pair.translation {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translation, forType: .string)
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(pair.translation == nil)
            .help("复制这句译文")
            .accessibilityLabel("复制这句译文")
        }
        .buttonStyle(.plain)
        .font(TLStyle.control)
        .foregroundStyle(.secondary)
        .padding(TLStyle.space1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(TLStyle.space1)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: TLStyle.space2) {
            Text("TLKit × \(controller.serviceName)")
                .font(TLStyle.footnote)
                .foregroundStyle(.tertiary)
            Spacer()
            // 快捷键只留不可发现的：朗读/清空的快捷键在各自按钮悬停提示里，
            // ⌘Enter 因实时自动翻译近乎冗余（功能保留，不占提示位）。
            Text("⌘1/⌘2 切换模式 · Esc/⌘W 关闭")
                .font(TLStyle.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, TLStyle.space3)
        .padding(.top, TLStyle.space2)
        .padding(.bottom, TLStyle.space2)
    }
}

/// 纯文本编辑区（NSTextView 包装）：SwiftUI TextEditor 自带不可控内边距，
/// 占位文字与输入文字易错位；这里 inset 全零，与占位文字共用同一外边距，天然对齐。
private struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isRichText = false
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.allowsUndo = true
            textView.delegate = context.coordinator
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        // 面板每次弹出 focusToken 递增，据此抢占第一响应者。
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                scroll.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextView
        var lastFocusToken: Int?
        init(_ parent: PlainTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
