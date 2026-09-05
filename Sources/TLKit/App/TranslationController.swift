import AppKit
import Foundation

/// 翻译流程中枢：快捷键 → 权限 → 取词 → 翻译 → 气泡 / 输入面板。
@MainActor
final class TranslationController: ObservableObject {
    static let shared = TranslationController()

    private let hotkeyManager = HotkeyManager()
    private let bubble = BubblePanelController()
    // 取词器两个渠道都编译：官网版常规使用；App Store 版仅在用户自行授予
    // 辅助功能权限后启用（彩蛋能力，不申请、不引导，见 run() 内分支）。
    private let selectionReader = SelectionReaderFactory.make()
    private var activeTask: Task<Void, Never>?

    private init() {}

    /// 启动时注册全局快捷键，并注入气泡内朗读回调。
    func start() {
        hotkeyManager.onActivate = { [weak self] key in self?.translateSelection(targetKey: key) }
        registerAllHotkeys()
        // 预热面板：提前完成 NSPanel + SwiftUI 视图构建，首次呼出零构建开销。
        bubble.prewarm()
        InputPanelController.shared.prewarm()
        bubble.onSpeakRequest = { text, lang in
            // 语言码来自翻译状态本身，比再检测一次准（纯汉字日/韩文检测会误判中文）。
            SpeechManager.shared.toggle(text: text, language: lang)
        }
        bubble.onDetailedRequest = { [weak self] source, translation in
            // 收起气泡，按设置偏好打开面板：逐句对照（按原文重翻）或简洁模式（直接带译文）。
            self?.bubble.dismiss()
            if ConfigStore.shared.current.bubbleOpensDetailed {
                InputPanelController.shared.showDetailed(source: source)
            } else {
                InputPanelController.shared.show(source: source, translation: translation)
            }
        }
        // 错误态引导：直接打开设置（翻译服务页），失败不再是死胡同。
        bubble.onOpenSettingsRequest = {
            SettingsWindow.present()
        }
        // 权限态「不再提醒」：记住选择，之后快捷键无权限时直开输入面板。
        bubble.onPermissionNeverRemind = { [weak self] in
            ConfigStore.shared.update { $0.suppressPermissionHint = true }
            self?.bubble.dismiss()
            InputPanelController.shared.show()
        }
    }

    /// 「翻译为」清单或快捷键配置变更后全量重注册。
    func applyHotkeyChange() {
        registerAllHotkeys()
    }

    /// 把清单里所有非空快捷键注册给 HotkeyManager（条目 ID 作 key）。
    private func registerAllHotkeys() {
        let targets = ConfigStore.shared.current.translateTargets
        hotkeyManager.registerAll(targets.map { (key: $0.id, shortcut: $0.hotkey) })
    }

    /// 全局快捷键入口：面板已显示 → 关闭（toggle）；否则尝试取词翻译。
    /// - Parameter targetKey: 触发的清单条目 ID；非默认槽条目携带自己的目标语言。
    func translateSelection(targetKey: String = TranslateTarget.defaultSlotID) {
        // Toggle 逻辑：气泡或输入面板任一可见时，再按快捷键 = 关闭，不再触发。
        if bubble.isVisible || InputPanelController.shared.isVisible {
            // 取消可能正在进行的翻译，避免其完成后又弹出气泡（复现：loading 中再按关闭）。
            activeTask?.cancel()
            bubble.dismiss()
            InputPanelController.shared.dismiss()
            return
        }
        let override = ConfigStore.shared.current.translateTargets
            .first { $0.id == targetKey }?.language
        activeTask?.cancel()
        activeTask = Task { await run(presetText: nil, targetOverride: override) }
    }

    /// 直接翻译指定文本（历史记录「重新翻译」入口，跳过取词）。
    func translateText(_ text: String) {
        activeTask?.cancel()
        activeTask = Task { await run(presetText: text, targetOverride: nil) }
    }

    // MARK: - 主流程

    /// - Parameter targetOverride: 触发条目自带的目标语言；nil = 用默认槽语言。
    private func run(presetText: String?, targetOverride: String?) async {
        // CGEvent 全局坐标（左上角原点），用于气泡定位。
        let mouse = CGEvent(source: nil)?.location ?? CGPoint(x: 200, y: 200)

        let text: String
        let truncated: Bool
        if let presetText {
            truncated = false
            text = presetText
        } else {
            #if APP_STORE
            // App Store 版默认不使用辅助功能权限（审核条款 2.4.5）：快捷键直接打开输入面板。
            // 彩蛋能力：用户自行在系统设置授予权限后，落入与官网版一致的取词路径。
            // 不弹系统授权窗、UI 不做任何引导——授权纯属用户自身行为。
            guard PermissionGate.ensureAccessibility(prompt: false) else {
                // 预设条目的热键 = 先把该条语言写进默认槽，再呼出面板。
                if let targetOverride,
                   targetOverride != ConfigStore.shared.current.defaultTargetLanguage {
                    ConfigStore.shared.setDefaultTargetLanguage(targetOverride)
                }
                InputPanelController.shared.show()
                return
            }
            #else
            // CGEvent.post() 需要 PostEvent 权限（系统设置 → 辅助功能）。
            // 不用系统授权弹窗（prompt: false）：那东西语气强硬还会和我们的气泡
            // 叠在一起双重轰炸；未授权时只出我们自己的柔和气泡，或直接退化为输入面板。
            let suppressed = ConfigStore.shared.current.suppressPermissionHint
            guard PermissionGate.ensureAccessibility(prompt: false) else {
                if suppressed {
                    InputPanelController.shared.show()
                } else {
                    bubble.show(.permissionNeeded, at: mouse)
                }
                return
            }
            #endif

            // 150ms 宽限的即时反馈：AX 直读通常几十毫秒内返回，不弹气泡，
            // 避免无选中场景「气泡一闪而过再切输入面板」的视觉跳动；
            // 仅慢路径（模拟 ⌘C 回退）超过宽限期时才弹「翻译中…」兜底。
            let feedbackTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled {
                    bubble.show(.loading(source: ""), at: mouse)
                }
            }

            guard let raw = await selectionReader.readSelection() else {
                feedbackTask.cancel()
                // 无选中文字 → 收起可能已弹出的气泡，弹出输入翻译面板（居中）。
                bubble.dismiss()
                InputPanelController.shared.show()
                return
            }
            feedbackTask.cancel()

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

        let target = targetOverride ?? ConfigStore.shared.current.defaultTargetLanguage
        do {
            let translation = try await service.translate(text, from: nil, to: target)
            guard !Task.isCancelled else { return }
            bubble.show(
                .result(source: text, translation: translation,
                        service: service.displayName, truncated: truncated,
                        sourceLang: Self.detectLanguage(from: text), targetLang: target),
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

    /// 检测文本语言（用于 TTS 选声）。委托 NaturalLanguage 框架，离线可用。
    static func detectLanguage(from text: String) -> String {
        LanguageCatalog.detect(text)
    }
}
