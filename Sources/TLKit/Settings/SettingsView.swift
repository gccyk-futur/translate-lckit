import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import SwiftUI

/// 设置窗口管理：侧边栏导航、稳定窗口尺寸；
/// 打开时切 .regular（进 Dock/Switcher），关闭后切回 .accessory（菜单栏 Agent）。
@MainActor
enum SettingsWindow {
    private static var windowController: NSWindowController?
    private static let delegate = SettingsPolicyDelegate()

    static func present() {
        if let wc = windowController {
            show(wc.window!)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "TLKit 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate.onBecomeKey = { removeSidebarToggle(from: window) }
        window.delegate = delegate
        windowController = NSWindowController(window: window)
        show(window)
    }

    static func close() {
        windowController?.window?.close()
    }

    private static func show(_ win: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        removeSidebarToggle(from: win)
    }

    /// macOS 26 上 .toolbar(removing: .sidebarToggle) 不生效，直接从 NSToolbar 移除侧栏折叠按钮。
    private static func removeSidebarToggle(from win: NSWindow) {
        guard let toolbar = win.toolbar else { return }
        for (index, item) in toolbar.items.enumerated().reversed()
        where item.itemIdentifier.rawValue.lowercased().contains("togglesidebar") {
            toolbar.removeItem(at: index)
        }
    }

}

/// 设置窗委托（顶层无隔离类，避免嵌套于 @MainActor 枚举导致 self 携带隔离）：
/// 关窗后切回 .accessory，Dock/Switcher 消失，app 不退出。
private final class SettingsPolicyDelegate: NSObject, NSWindowDelegate {
    var onBecomeKey: (@MainActor () -> Void)?

    func windowWillClose(_ notification: Notification) {
        // 延迟一帧让系统完成窗口关闭动画再切换策略，避免菜单栏图标消失。
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 委托回调在主线程触发，同步假设主线程隔离。
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            self.onBecomeKey?()
        }
    }
}

/// 设置页签（侧边栏导航项）。
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, services, voiceHistory, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .services: return "翻译服务"
        case .voiceHistory: return "语音与历史"
        case .privacy: return "隐私"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .services: return "character.book.closed"
        case .voiceHistory: return "speaker.wave.2"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// 设置页（侧边栏 + 分组表单；Esc 或「关闭」退出）。
struct SettingsView: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var baiduSecret = KeychainStore.get(.baiduSecret) ?? ""
    @State private var openaiKey = KeychainStore.get(.openaiKey) ?? ""
    @State private var azureKey = KeychainStore.get(.azureKey) ?? ""
    @State private var permissionRefreshID = UUID()
    @State private var restartRequested = false
    @State private var selectedPane: SettingsPane? = .general
    @State private var testingKey: String?
    @State private var testMessage: [String: String] = [:]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var accessibilityGranted: Bool {
        _ = permissionRefreshID
        return AXIsProcessTrusted()
    }

    private var needsRestart: Bool {
        restartRequested && accessibilityGranted
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                // 内容列限宽居中，标题与分组卡片左缘对齐（系统设置的版式）。
                VStack(alignment: .leading, spacing: 0) {
                    Text((selectedPane ?? .general).title)
                        .font(.system(size: 22, weight: .bold))
                        .padding(.leading, 20)
                        .padding(.top, 16)

                    paneContent
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)

                Divider()

                // 右下角固定关闭按钮；.cancelAction 即 Esc。
                HStack(spacing: 10) {
                    Spacer()
                    Button("关闭") { SettingsWindow.close() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane ?? .general {
        case .general: generalPane
        case .services: servicesPane
        case .voiceHistory: voiceHistoryPane
        case .privacy: privacyPane
        case .about: aboutPane
        }
    }

    private var generalPane: some View {
        Form {
            Section("启动") {
                Toggle("开机启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // 注册失败（如 app 不在 /Applications）时回退开关状态。
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("外观") {
                Picker("主题", selection: Binding(
                    get: { config.current.appearance },
                    set: { mode in
                        config.update { $0.appearance = mode }
                        AppearanceManager.apply()
                    }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("跟随系统将随 macOS 外观自动切换；浅色/深色强制指定")
            }

            Section("权限") {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("辅助功能")
                            .font(.system(size: 13))
                        Text(accessibilityGranted ? "已授权" : "未授权 — 划词翻译需要此权限")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        Button("去授权") {
                            restartRequested = true
                            _ = PermissionGate.ensureAccessibility(prompt: true)
                        }
                        .controlSize(.small)
                    } else {
                        Button("打开系统设置") {
                            PermissionGate.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }

                if needsRestart {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("权限已授权，请重启 TLKit")
                                .font(.system(size: 13))
                            Text("系统 TCC 缓存需重启 App 才能生效。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重启 TLKit") {
                            restartApplication()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                permissionRefreshID = UUID()
            }
            Section("快捷键") {
                LabeledContent("翻译选中内容") {
                    ShortcutRecorderView(shortcut: Binding(
                        get: { config.current.hotkey },
                        set: { newValue in
                            config.update { $0.hotkey = newValue }
                            TranslationController.shared.applyHotkeyChange()
                        }
                    ))
                }
            }

            Section("气泡") {
                Picker("自动消失", selection: Binding(
                    get: { config.current.autoDismissSeconds },
                    set: { seconds in config.update { $0.autoDismissSeconds = seconds } }
                )) {
                    Text("关闭").tag(0)
                    Text("5 秒").tag(5)
                    Text("8 秒").tag(8)
                    Text("15 秒").tag(15)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var servicesPane: some View {
        Form {
            Section("翻译服务") {
                Picker("服务", selection: Binding(
                    get: { config.current.service },
                    set: { kind in config.update { $0.service = kind } }
                )) {
                    ForEach(ServiceKind.availableCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }

                Picker("目标语言", selection: targetLanguageBinding) {
                    ForEach(Self.commonLanguages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                    Text("自定义…").tag(Self.customLanguageTag)
                }

                if targetLanguageBinding.wrappedValue == Self.customLanguageTag {
                    TextField("语言代码", text: Binding(
                        get: { config.current.targetLanguage },
                        set: { lang in config.update { $0.targetLanguage = lang } }
                    ), prompt: Text("如 zh / en / ja"))
                }
            }

            Section("输入翻译") {
                Picker("默认方向", selection: Binding(
                    get: { config.current.defaultDirection },
                    set: { dir in config.update { $0.defaultDirection = dir } }
                )) {
                    ForEach(TranslationDirection.allCases, id: \.self) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
            }

            switch config.current.service {
            case .baidu:
                Section("百度翻译") {
                    TextField("API Key", text: Binding(
                        get: { config.current.baidu.apiKey },
                        set: { apiKey in config.update { $0.baidu.apiKey = apiKey } }
                    ))

                    SecureField("Secret Key", text: $baiduSecret)
                        .onChange(of: baiduSecret) { _, newValue in
                            KeychainStore.set(newValue, for: .baiduSecret)
                        }

                    Text("适用「百度智能云」机器翻译：在 ai.baidu.com 控制台创建应用，获取 API Key 与 Secret Key；不是百度翻译开放平台（APP ID 那种）。密钥仅存本机 Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    testRow(key: "baidu") { runTranslationTest(.baidu) }
                }
            case .openai:
                Group {
                    Section("AI 大模型接口") {
                        TextField("Base URL", text: Binding(
                            get: { config.current.openai.baseURL },
                            set: { url in config.update { $0.openai.baseURL = url } }
                        ), prompt: Text("如 https://api.deepseek.com/v1"))

                        TextField("模型", text: Binding(
                            get: { config.current.openai.model },
                            set: { model in config.update { $0.openai.model = model } }
                        ), prompt: Text("如 deepseek-chat"))

                        SecureField("API Key", text: $openaiKey)
                            .onChange(of: openaiKey) { _, newValue in
                                KeychainStore.set(newValue, for: .openaiKey)
                            }

                        Text("兼容 Chat Completions 格式，可接 DeepSeek、智谱、Kimi、Moonshot 等大模型 API。API Key 仅存本机 Keychain，Base URL 兼容带 /v1 与不带 /v1 的写法。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        testRow(key: "openai") { runTranslationTest(.openai) }
                    }
                    promptSection
                }
            case .ollama:
                Group {
                    Section("Ollama") {
                        TextField("服务地址", text: Binding(
                            get: { config.current.ollama.host },
                            set: { host in config.update { $0.ollama.host = host } }
                        ), prompt: Text("http://localhost:11434"))

                        TextField("模型", text: Binding(
                            get: { config.current.ollama.model },
                            set: { model in config.update { $0.ollama.model = model } }
                        ), prompt: Text("如 qwen2.5:7b"))

                        Text("需先在本机启动 Ollama 并拉取模型（ollama pull <模型名>）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        testRow(key: "ollama") { runTranslationTest(.ollama) }
                    }
                    promptSection
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 模型服务的系统提示词（只读展示，与请求实际使用的一致）。
    private var promptSection: some View {
        Section("提示词（只读）") {
            Text(OpenAICompatibleTranslator.systemPrompt(for: config.current.targetLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var voiceHistoryPane: some View {
        Form {
            Section("语音与历史") {
                Picker("朗读语音", selection: Binding(
                    get: { config.current.tts.provider },
                    set: { provider in config.update { $0.tts.provider = provider } }
                )) {
                    ForEach(TTSProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                Picker("系统声音", selection: Binding(
                    get: { config.current.tts.systemVoice },
                    set: { voice in config.update { $0.tts.systemVoice = voice } }
                )) {
                    Text("自动").tag("")
                    ForEach(systemVoiceOptions, id: \.identifier) { voice in
                        Text("\(voice.name)（\(voice.language)）").tag(voice.identifier)
                    }
                }

                HStack {
                    Button("试听系统声音") {
                        Task { try? await SystemSpeechService().speak("声音试听。", language: "zh") }
                    }
                    .controlSize(.small)
                    Spacer()
                }

                Text("所选声音语种与朗读文本不一致时，自动回退为按文本语言选声。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if config.current.tts.provider == .azure {
                    TextField("区域", text: Binding(
                        get: { config.current.tts.azureRegion },
                        set: { region in config.update { $0.tts.azureRegion = region } }
                    ), prompt: Text("如 eastasia"))

                    SecureField("订阅密钥", text: $azureKey)
                        .onChange(of: azureKey) { _, newValue in
                            KeychainStore.set(newValue, for: .azureKey)
                        }

                    Picker("神经语音", selection: Binding(
                        get: { config.current.tts.azureVoice },
                        set: { voice in config.update { $0.tts.azureVoice = voice } }
                    )) {
                        Text("自动").tag("")
                        ForEach(Self.azureVoiceOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    Text("未配置完整时自动回退系统语音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    testRow(key: "azure") { runAzureTest() }
                }

                Picker("历史保留", selection: Binding(
                    get: { config.current.historyMaxCount },
                    set: { count in
                        config.update { $0.historyMaxCount = count }
                        HistoryStore.shared.applyLimit()
                    }
                )) {
                    Text("100 条").tag(100)
                    Text("500 条").tag(500)
                    Text("1000 条").tag(1000)
                    Text("3000 条").tag(3000)
                    Text("5000 条").tag(5000)
                }

                LabeledContent("当前记录") {
                    Button("清空全部", role: .destructive) {
                        HistoryStore.shared.clear()
                    }
                    .disabled(history.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyPane: some View {
        Form {
            Section {
                Text("TLKit 没有后台服务器，不使用任何分析或追踪框架，所有数据仅存储在你的 Mac 本地。")
            }

            Section("数据去向") {
                Text("译文请求仅发往你配置的翻译服务（Ollama 完全本机）；朗读由系统本机合成，或发往你配置的 Azure 区域。")
                Text("密钥仅存本机 Keychain，不写入配置文件、不上传。")
            }

            Section("权限") {
                Text("辅助功能权限仅用于模拟 ⌘C 获取选中文字，可随时在系统设置中撤销。")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TLKit")
                            .font(.system(size: 20, weight: .semibold))
                        Text("macOS 极简划词翻译工具")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("版本") {
                LabeledContent("版本号", value: Self.versionString)
                LabeledContent("分发渠道", value: Self.channelName)
            }

            Section("联系") {
                Link("tlkit@ckai.me", destination: URL(string: "mailto:tlkit@ckai.me")!)
                Link("支持与帮助", destination: URL(string: "https://ckai.me/tlkit/support.html")!)
                Link("隐私政策", destination: URL(string: "https://ckai.me/tlkit/privacy.html")!)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 语音选项

    /// 本机已装系统声音（过滤到 app 支持朗读的语种）。
    private var systemVoiceOptions: [AVSpeechSynthesisVoice] {
        let prefixes = ["zh", "en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in prefixes.contains { voice.language.hasPrefix($0) } }
            .sorted { $0.language < $1.language }
    }

    private static let azureVoiceOptions: [(id: String, label: String)] = [
        ("zh-CN-XiaoxiaoNeural", "晓晓 · 中文女"),
        ("zh-CN-YunxiNeural", "云希 · 中文男"),
        ("zh-CN-YunjianNeural", "云健 · 中文男"),
        ("en-US-JennyNeural", "Jenny · 美英女"),
        ("en-US-GuyNeural", "Guy · 美英男"),
        ("en-GB-SoniaNeural", "Sonia · 英英女"),
        ("ja-JP-NanamiNeural", "Nanami · 日语女"),
        ("ko-KR-SunHiNeural", "SunHi · 韩语女"),
    ]

    // MARK: - 目标语言选择

    private static let customLanguageTag = "__custom__"
    private static let commonLanguages: [(code: String, label: String)] = [
        ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("ru", "俄语"),
        ("pt", "葡萄牙语"), ("it", "意大利语"),
    ]

    /// 目标语言选择：常见语言下拉 + 「自定义…」回退为代码输入框。
    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: {
                let value = config.current.targetLanguage
                return Self.commonLanguages.contains { $0.code == value } ? value : Self.customLanguageTag
            },
            set: { newValue in
                guard newValue != Self.customLanguageTag else { return }
                config.update { $0.targetLanguage = newValue }
            }
        )
    }

    // MARK: - 服务测试

    /// 「测试连接」行：发一条短译文 / 试读一句，结果内联展示。
    private func testRow(key: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(testingKey == key ? "测试中…" : "测试连接") { run() }
                .controlSize(.small)
                .disabled(testingKey != nil)

            if let message = testMessage[key] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("✓") ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func runTranslationTest(_ kind: ServiceKind) {
        testingKey = kind.rawValue
        testMessage[kind.rawValue] = nil
        Task {
            do {
                let service = try ServiceFactory.make(kind)
                let result = try await service.translate("Hello", to: config.current.targetLanguage)
                testMessage[kind.rawValue] = "✓ 译文：\(result)"
            } catch {
                testMessage[kind.rawValue] = error.localizedDescription
            }
            testingKey = nil
        }
    }

    private func runAzureTest() {
        testingKey = "azure"
        testMessage["azure"] = nil
        Task {
            let service = AzureSpeechService(
                region: config.current.tts.azureRegion,
                key: KeychainStore.get(.azureKey) ?? ""
            )
            do {
                try await service.speak("语音测试。", language: "zh")
                testMessage["azure"] = "✓ 已播放测试语音"
            } catch {
                testMessage["azure"] = error.localizedDescription
            }
            testingKey = nil
        }
    }

    // MARK: - 关于

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)（\(build)）"
    }

    private static var channelName: String {
        #if APP_STORE
        return "App Store"
        #else
        return "官网版"
        #endif
    }

    private func restartApplication() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

/// 快捷键录制控件：点击进入录制，按下带修饰键的组合即录入；Esc 取消。
/// 交互参照系统「键盘 → 键盘快捷键」。
struct ShortcutRecorderView: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    /// 纯修饰键的 keyCode（按下它们不算录入）。
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]

    var body: some View {
        Button(action: { recording ? stopRecording() : startRecording() }) {
            Text(recording ? "按下新的快捷键…" : shortcut.displayString)
                .monospaced()
                .frame(minWidth: 64)
        }
        .help(recording ? "按下新的快捷键（支持 F1-F12 单键），Esc 取消" : "点击后按下新的快捷键")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc：取消录制
                stopRecording()
                return nil
            }
            if Self.modifierKeyCodes.contains(event.keyCode) { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbon = Shortcut.carbonModifiers(from: flags)
            // 允许无修饰键的单键绑定（如 F3），也支持组合键。
            shortcut = Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
