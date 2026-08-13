import AppKit
import Foundation

/// 翻译流程中枢：快捷键 → 权限 → 取词 → 翻译 → 气泡 / 输入面板。
@MainActor
final class TranslationController: ObservableObject {
    static let shared = TranslationController()

    private let hotkeyManager = HotkeyManager()
    private let bubble = BubblePanelController()
    private let selectionReader = SelectionReaderFactory.make()
    private var activeTask: Task<Void, Never>?

    private init() {}

    /// 启动时注册全局快捷键，并注入气泡内朗读回调。
    func start() {
        hotkeyManager.onActivate = { [weak self] in self?.translateSelection() }
        hotkeyManager.register(shortcut: ConfigStore.shared.current.hotkey)
        bubble.onSpeakRequest = { text in
            SpeechManager.shared.toggle(text: text, language: Self.detectLanguage(from: text))
        }
        bubble.onDetailedRequest = { [weak self] text in
            // 收起气泡，把原文送进翻译面板的逐句对照模式。
            self?.bubble.dismiss()
            InputPanelController.shared.showDetailed(source: text)
        }
    }

    /// 快捷键配置变更后重新注册。
    func applyHotkeyChange() {
        hotkeyManager.register(shortcut: ConfigStore.shared.current.hotkey)
    }

    /// 全局快捷键入口：面板已显示 → 关闭（toggle）；否则尝试取词翻译。
    func translateSelection() {
        // Toggle 逻辑：气泡或输入面板任一可见时，再按快捷键 = 关闭，不再触发。
        if bubble.isVisible || InputPanelController.shared.isVisible {
            // 取消可能正在进行的翻译，避免其完成后又弹出气泡（复现：loading 中再按关闭）。
            activeTask?.cancel()
            bubble.dismiss()
            InputPanelController.shared.dismiss()
            return
        }
        activeTask?.cancel()
        activeTask = Task { await run(presetText: nil) }
    }

    /// 直接翻译指定文本（历史记录「重新翻译」入口，跳过取词）。
    func translateText(_ text: String) {
        activeTask?.cancel()
        activeTask = Task { await run(presetText: text) }
    }

    // MARK: - 主流程

    private func run(presetText: String?) async {
        // CGEvent 全局坐标（左上角原点），用于气泡定位。
        let mouse = CGEvent(source: nil)?.location ?? CGPoint(x: 200, y: 200)

        let text: String
        let truncated: Bool
        if let presetText {
            truncated = false
            text = presetText
        } else {
            // CGEvent.post() 需要 PostEvent 权限（系统设置 → 辅助功能）。
            guard PermissionGate.ensureAccessibility(prompt: true) else {
                bubble.show(.permissionNeeded, at: mouse)
                return
            }

            guard let raw = await selectionReader.readSelection() else {
                // 无选中文字 → 弹出输入翻译面板（居中）。
                InputPanelController.shared.show()
                return
            }

            truncated = raw.count > 3000
            text = String(raw.prefix(3000))
        }
        bubble.show(.loading(source: text), at: mouse)

        let service: TranslationService
        do {
            service = try ServiceFactory.makeActive()
        } catch {
            bubble.show(.error(message: error.localizedDescription), at: mouse)
            return
        }

        let target = ConfigStore.shared.current.targetLanguage
        do {
            let translation = try await service.translate(text, to: target)
            guard !Task.isCancelled else { return }
            bubble.show(
                .result(source: text, translation: translation,
                        service: service.displayName, truncated: truncated),
                at: mouse
            )
            // 成功即入历史（滚动淘汰在 HistoryStore 内部处理）。
            HistoryStore.shared.append(HistoryItem(
                sourceText: text,
                resultText: translation,
                targetLang: target,
                service: service.displayName
            ))
        } catch {
            guard !Task.isCancelled else { return }
            bubble.show(.error(message: error.localizedDescription), at: mouse)
        }
    }

    // MARK: - 语言检测

    /// 从文本推断口语语言（用于 TTS 选声）。
    /// CJK 统一表意文字 → 中文，假名 → 日语，谚文 → 韩语，其余 → 英语。
    static func detectLanguage(from text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh" }
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }
        return "en"
    }
}
