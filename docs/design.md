# TLKit 设计文档

TLKit = Translate / Language Kit，macOS 极简划词翻译工具。本文档描述**当前已实现的架构**。

| 项目 | 说明 |
|---|---|
| 应用名 | TLKit |
| Bundle ID | `me.ckai.translate` |
| 当前版本 | v2.0.0（官网版已发布，App Store 版待提审） |
| 最低系统要求 | macOS 14.0（Sonoma） |
| 形态 | 菜单栏常驻工具（LSUIElement，无 Dock 图标） |
| 发行渠道 | ① Mac App Store（免费，沙盒）② Developer ID 官网版（公证，无沙盒） |
| 网络模型 | 纯客户端工具，不自带任何服务器，仅调用用户自行配置的第三方 API |
| 技术栈 | Swift 6.0 / AppKit + SwiftUI，XcodeGen 管理工程，无第三方依赖 |

---

## 1. 产品概述

TLKit 提供两条翻译链路：

1. **划词翻译（快速模式）**：在任意应用中选中文字 → 全局快捷键 → 鼠标旁弹出气泡展示译文。
2. **输入翻译（面板模式）**：无选中文字时按快捷键（或菜单栏入口）→ 居中弹出翻译面板，手动输入、实时翻译；面板支持「简洁 / 详细」两种展示形态。

设计原则：

1. **克制**：不做 OCR、不做插件系统、不做多开、不做账号体系。
2. **纯本地工具**：除翻译 API 请求外不产生任何网络流量；所有数据（历史、配置）只存本机。
3. **纵深打磨**：围绕已有链路打磨体验，不横向拓展功能面。

## 2. 非目标（明确不做）

- 截图翻译 / OCR
- 划词自动取词（悬停取词）——只支持快捷键触发
- 翻译插件市场 / 自定义插件
- 云端同步、账号、付费
- macOS 14 以下系统支持
- iOS / iPad / 其他平台

## 3. 核心用户流程

```
按下全局快捷键（「翻译为」清单条目各自绑定，默认槽默认 ⌥D）
        │
   面板/气泡可见？──── 是 ──▶ 关闭（toggle）
        │ 否
        ▼
工具模拟 ⌘C 取词（先备份剪贴板，结束后还原）
        │
   ┌────┴────┐
 取到文字    未取到
   │          └──▶ 弹出「输入翻译面板」（居中，见 4.5）
   ▼
气泡出现在鼠标位置附近，显示"翻译中…"
        │
        ▼
调用当前激活的翻译服务（系统翻译 / 百度智能云 / AI 大模型 / Ollama）
目标语言 = 触发快捷键对应清单条目的语言
        │
   ┌────┴────┐
  成功       失败 ──▶ 气泡显示错误原因（红字）
   ▼
气泡展示：原文（灰色小字）+ 译文 + 工具条
（打开面板 / 语速 / 朗读 / 复制 / 服务标识）
写入本地历史记录
        │
        ▼
消失：点击其他窗口 / Esc / 自动消失倒计时（悬停暂停、播报中顺延、可配置）
```

气泡的「打开面板」按钮按设置偏好进入面板的**详细模式**（逐句对照，重新翻译）或**简洁模式**（直接携带气泡译文）。

## 4. 功能详细说明

### 4.1 菜单栏常驻

- 启动后仅在菜单栏显示图标（水墨「译」模板 PNG，不走 asset catalog——Xcode 26 产出的 Assets.car 在 macOS 14 上解析失败；随深浅色自动反色）。
- 点击图标展开菜单：

| 菜单项 | 说明 |
|---|---|
| 输入翻译 | 打开输入翻译面板 |
| 翻译为 | 子菜单快速切换默认目标语言（与设置页「翻译为」清单默认槽同源） |
| 翻译历史… | 打开历史窗口 |
| 设置… | 打开设置窗口 |
| 退出 TLKit | 退出应用（与 ⌘Q 一样需二次确认） |

- 菜单项不标注快捷键（菜单栏内的 ⌘ 标注仅在菜单展开时有效，展示会造成歧义）。
- 无 Dock 图标，无主窗口。`Info.plist` 设置 `LSUIElement = true`。
- **macOS 14 刘海机缓解**：菜单栏空间不足时系统会把状态项静默泊到屏外（isVisible 说谎、重建无用）。启动 3 秒后检测状态项窗口中点是否在任一屏幕内，不在则自动打开一次设置窗口提示 App 活着（每启动最多一次）。另有看门狗：窗口被系统移除（SystemUIServer 重启等）或屏幕参数变化（接/拔外显）时重建状态项。

### 4.2 划词取词

- **单一通道：模拟 ⌘C + 剪贴板**（直装与沙盒实测均可用；早期设计的 AX 通道已移除）。
  备份当前剪贴板 → `CGEvent` 模拟 ⌘C → 轮询 `NSPasteboard.changeCount` 直到变化（上限 1 秒）→ 读取纯文本 → 流程结束后还原剪贴板。
- 需要**辅助功能**权限（PostEvent）。
  - 官网版：未授权时气泡引导用户前往"系统设置 → 隐私与安全性 → 辅助功能"（可选「不再提醒」，之后直开输入面板）。
  - App Store 版：不申请、不引导（审核条款 2.4.5），快捷键直接打开输入面板；**用户自行在系统设置中授予权限后，划词翻译自动解锁**（彩蛋能力，设置页仅在已授权后显示状态确认，无任何引导）。
- 边界情况：
  - 超时未取到文字 → 视为"无选中内容"，弹出输入翻译面板。
  - 取到的文本超过 3000 字符 → 截断并标注"已截断"。
- 剪贴板还原：逐 item 备份全部类型数据（文本、图片、文件 URL 等），原样写回；个别特殊类型可能无法完美还原，属已知限制。

### 4.3 全局快捷键（「翻译为」清单 + 可自定义）

- 「翻译为」清单（设置 → 翻译设置）：第 1 条是固定**默认槽**（不可删，输入面板/状态栏快切/历史重翻等无快捷键上下文的目标语言来源）；其余条目为快捷键预设，选中文字按对应快捷键即翻成该语言（不改变默认）。
- 条目快捷键可录制、可清空；默认槽默认 ⌥D。支持组合键与单键（如 F14）。
- **toggle 语义**：气泡或输入面板可见时再按快捷键 = 关闭，不重复触发。
- 存储：`translateTargets` 数组（id + 语言码 + 修饰键掩码 + keyCode）存入 config.json，应用启动与修改时全量重注册（Carbon `RegisterEventHotKey`，沙盒内可用且零额外权限）；撞键时后者跳过并记日志。
- App Store 版（未授权辅助功能时）：条目热键 = 把该条语言写进默认槽 + 呼出输入面板。

### 4.4 翻译气泡（快速模式，App Store 版见 4.2 彩蛋说明）

**外观（遵循 HIG）：**

- 无边框圆角卡片，`NSVisualEffectView(.popover)` 毛玻璃，跟随系统深浅色。
- 宽度 380pt，高度自适应（上限约 400pt），超出可滚动。
- 内容自上而下：
  1. 原文：次要色、小号字体，最多 3 行，溢出省略。
  2. 译文：正文主内容，可滚动、可选中复制。
  3. 语言行：原语言 → 目标语言标签。
  4. 底部工具条：服务标识（如"TLKit × Ollama · qwen2.5"）+ 打开面板 / 朗读速度 / 朗读 / 复制译文图标按钮。
  5. 语速滑条（0.5x~2.0x，按需展开）。

**行为：**

- 位置：鼠标点附近；下方空间不足则置于上方；超出屏幕边缘时收回屏幕内。
- `NSPanel` + `nonactivatingPanel` + `.popUpMenu` 层级：弹出**不抢走**当前应用的焦点。
- 三态：加载中 / 结果 / 错误（红色文字说明原因）。
- Esc、点击其他窗口（本应用与其他应用均监听）关闭；结果态自动消失倒计时可配置（悬停暂停；**TTS 播报中同样顺延**，播完才走消失流程）。
- 朗读快捷键：空格读译文、⇧空格读原文（均可在设置中改）；「打开面板」进入详细或简洁模式可在设置中选择。
- 面板实现要点与踩坑记录见附录 A。

### 4.5 输入翻译面板（简洁 / 详细双模式）

无选中文字时的主翻译界面，类 Google 翻译的布局，居中浮窗。

**通用：**

- 顶栏：源语言（自动检测 + 可手动指定，纠正检测误判）⇄ 目标语言（可交换方向）+「简洁 | 详细」分段切换。
- 底栏：`TLKit × {服务名}` + 快捷键提示（朗读译文 ⌘R / 朗读原文 ⇧⌘R / 清空 ⌘K / 模式切换 ⌘1 ⌘2——全部可在设置中改）。
- 面板弹出时**激活 TLKit**（外部输入工具——语音输入、输入法——只会把文本送给活跃应用）并自动获焦输入框；关闭时把焦点归还给原前台应用（仅当用户期间未自行切换应用）。
- 输入区为零内边距的 NSTextView 包装（解决占位文字与输入文字错位问题）；⌘V/⌘C/⌘X/⌘A/⌘Z 走主菜单编辑菜单下发。
- 朗读语义约定：不加修饰键读译文、加 ⇧ 读原文（气泡与面板一致）。

**简洁模式（640×268）：**

- 左右双栏：左栏输入原文，右栏展示译文。
- 实时翻译：输入停顿 0.6s 自动翻译；⌘Enter 立即触发；清空输入清空结果。
- 左栏工具：朗读原文、清空；右栏工具：复制译文、朗读译文、语速调节。

**详细模式（760×520，逐句对照）：**

- 原文按句拆分（CJK 标点直接切；拉丁句号仅在后随空白时切，避免切断小数/缩写；超过 40 句退化为整段一条）。
- 逐句并发翻译（上限 4 路），每句一张卡片：原文在上（次要层级）、译文在下。
- **悬停映射**：鼠标悬停任一卡片整卡高亮（accent 色 12% 透明度），建立译文 ↔ 原文的视觉对应。
- 悬停时出现句子工具条：朗读这句原文 / 朗读这句译文 / 复制这句译文。
- 交换语言方向会整体重译；详情模式朗读 = 拼接各句译文；切回简洁模式携带译文不丢失。

### 4.6 翻译服务

统一服务接口（`TranslationService`），同一时间只有一个**激活服务**，在设置 → 翻译引擎中切换。「翻成什么」归「翻译设置」页的「翻译为」清单管理，引擎页只管「用谁翻」。每个外部服务都有「测试连接」按钮（后台真实翻译一次验证连通性与耗时，译文不展示；Azure 为一次语音合成）。

#### 系统翻译

- macOS 26+ 内置翻译引擎：免费、离线、免配置、隐私最佳；低版本系统下在清单中隐藏。

#### 百度智能云机器翻译

- 凭证：**API Key + Secret Key**（百度智能云控制台创建应用获得；不是翻译开放平台的 APP ID 那套）。
- 协议：OAuth2 client_credentials 获取 token（缓存 30 天）→ `POST /rpc/2.0/mt/texttrans/v1`。
- 设置页对服务归属与凭证类型有明确说明文案，避免与开放平台混淆。

#### AI 大模型（OpenAI 兼容格式）

- 配置项：Base URL、API Key、模型名。
- 协议：标准 `POST /chat/completions`，兼容一切 OpenAI 格式服务（DeepSeek、Moonshot、智谱、OpenAI 官方等）。
- 系统提示词在设置页**只读可见**（"你是一个翻译引擎。把用户发送的文本翻译成{目标语言}。只输出译文…"，随默认目标语言动态变化）。
- 服务展示名带模型名（如 "AI · deepseek-chat"），气泡底栏与历史记录可见。

#### Ollama（本地模型）

- 配置项：主机地址（默认 `http://localhost:11434`）、模型名。
- 复用 OpenAI 协议客户端，仅界面上作为独立条目；无 Key 需求，全程本机流量。

### 4.7 TTS 朗读

- 触发点：气泡朗读（默认译文，⇧ 读原文）；输入面板分别朗读原文/译文；详细模式逐句朗读；历史详情朗读原文/译文/解读。
- 语速：0.5x~2.0x 可调（气泡与面板内嵌滑条），全局生效。
- 供应商（设置 → 语音中选其一）：

| 供应商 | 配置 | 说明 |
|---|---|---|
| 系统发音 | 声音可下拉选择（本机已装、按语种过滤）+ 试听 | `AVSpeechSynthesizer`，免费离线，默认选项 |
| Azure Speech | Key + Region + 神经语音可选（晓晓/云希/Jenny/Guy 等） | 官方 REST API 合成 mp3 播放 |

- **声音回退规则**：所选声音语种与朗读文本不一致时，自动回退为按文本语言选声（优雅降级，不出怪腔）。
- 试听语跟随所选声音的语种（试听的本意是听声音效果），选「自动」时跟随界面语言。
- Azure 未配置完整时自动回退系统发音；播放中再次点击 = 停止；面板/气泡关闭时自动停止。

### 4.8 翻译历史、统计与星标词典（本地）

- 每次翻译成功自动写入：时间、原文、译文、目标语言、所用服务（含模型名）。
- 输入面板实时翻译走**去重追加**（同一文本连续输入只更新最新一条，不刷屏；星标与解读在更新时保留）。
- 存储：`Application Support/TLKit/history.json`（MAS 版位于沙盒 Container 内），纯本地；新增字段自定义解码兼容老数据。
- **容量设置**：保留条数 100 ~ 5000 可配，默认 500，超出滚动淘汰最旧记录。
- 历史窗口（菜单栏 → 翻译历史…）：
  - 左侧列表：时间 + 原文摘要 + 行内星标开关；顶部搜索框按原文/译文过滤；工具栏「仅看星标」过滤。
  - 右侧详情：完整原文 + 译文 + 朗读 + 复制 +「重新翻译」（**原地重翻**：就地更新该条译文与引擎，不跳转气泡）。
  - 操作：删除单条、清空全部（二次确认）。
- **星标即词典**：星标条目详情页出现「词典解读」区——按**已配置完整**的 AI 引擎（AI 大模型 / Ollama，与当前激活引擎无关）逐个给出「生成解读」按钮，生成音标/词性/释义/例句（界面语言撰写，≤300 字），结果持久化在条目上，可朗读、可重新生成。系统翻译/百度不能吃提示词，不在其列。
- **统计与导出**（设置 → 历史与统计）：累计/今日/本月/星标条数，按引擎与按目标语言分布——全部从现有历史推导，零埋点；导出 JSON / CSV（NSSavePanel 自选位置，CSV 带 UTF-8 BOM）。

### 4.9 设置窗口

采用**侧边栏导航（NavigationSplitView）+ 分组表单**的成熟模式，7 个页签：

| 页签 | 内容 |
|---|---|
| 通用 | 开机启动（SMAppService 登录项）、主题（跟随系统/浅色/深色）、界面语言（跟随系统/10 语种指定，重启生效）；辅助功能权限状态与授权引导（官网版）/ 高级玩家彩蛋（商店版） |
| 翻译设置 | 「翻译为」清单（默认槽 + 快捷键预设）、面板快捷键（朗读译文/朗读原文/简洁/逐句对照/清空）、气泡区（朗读键、按钮形态偏好、自动消失时间，仅官网版） |
| 翻译引擎 | 激活服务选择、各服务凭证配置、服务说明文案、测试连接、模型服务提示词只读展示 |
| 语音 | TTS 供应商、系统声音选择 + 试听、朗读速度、Azure 区域/密钥/神经语音 |
| 历史与统计 | 历史保留条数、当前记录与清空、统计（累计/今日/本月/星标 + 按引擎/按目标语言分布）、导出 JSON/CSV |
| 隐私 | 数据去向与权限说明的精简视图（完整版见仓库 PRIVACY.md） |
| 关于 | 应用图标、版本号 + build、分发渠道（App Store / 官网版，编译期宏区分）、联系方式 |

**窗口行为：**

- Esc / ⌘W 关闭（关闭按钮绑定 `.keyboardShortcut(.cancelAction)`）。
- 打开时 `NSApp.setActivationPolicy(.regular)`（临时获得 Dock 图标与标准窗口行为），关闭时回 `.accessory`。
- 敏感项（API Key）使用 SecureField（小眼睛可切明文），密钥只存 Keychain，配置文件与 UserDefaults 中不出现明文。

## 5. HIG 合规要点

1. 菜单栏图标为模板渲染 PNG，自动适配深浅色与辅助功能对比度。
2. 颜色全部使用语义色（`.primary` / `.secondary` / `.quaternary` 等），不写死色值，原生支持深色模式。
3. 气泡窗口不激活、不抢焦点，符合"辅助浮层"定位；输入面板因需要接受外部输入而主动激活，关闭归还焦点。
4. 所有图标按钮提供 VoiceOver 标签、提示（tooltip）与约 28pt 命中区。
5. 键盘可达：设置与历史窗口支持标准 Tab 导航、Esc / ⌘W 关闭。
6. 间距遵循 8pt 栅格，圆角/字号集中于设计令牌（`TLStyle`）。

## 6. 技术架构

### 6.1 模块划分

```
┌─────────────────────────────────────────────────┐
│                     App 壳层                     │
│   状态项 · 生命周期 · TranslationController      │
├──────────┬──────────┬──────────┬────────────────┤
│ Hotkey   │Selection │Translate │     Speech     │
│ Carbon   │模拟 ⌘C   │服务协议   │ 系统/Azure TTS │
│ 多键注册  │剪贴板备份 │系统/百度  │ 声音选择/回退  │
│          │还原      │OpenAI/   │                │
│          │          │Ollama    │                │
├──────────┴──────────┴──────────┴────────────────┤
│ ConfigStore（config.json · 缺字段容错）           │
│ HistoryStore（JSON · 滚动淘汰 · 去重追加 · 统计/导出）│
│ DictionaryInterpreter（星标解读 · AI 引擎提示词）  │
│ KeychainStore（SecItem 封装）                    │
├─────────────────────────────────────────────────┤
│                      UI 层                       │
│ BubblePanel · InputPanel(简洁/详细) ·            │
│ SettingsWindow · HistoryWindow · TLStyle 令牌    │
└─────────────────────────────────────────────────┘
```

`TranslationController` 是流程中枢：快捷键（清单条目）→ 权限 → 取词 → 翻译 → 气泡 / 输入面板调度。

### 6.2 关键技术选型

| 问题 | 选型 | 理由 |
|---|---|---|
| 全局快捷键 | Carbon `RegisterEventHotKey` | 沙盒内可用且零权限，实测验证 |
| 取词 | 模拟 ⌘C + 剪贴板（单通道） | 直装/沙盒实测均可用；AX 通道兼容面窄已移除 |
| 气泡/面板 | `NSPanel` + `NSVisualEffectView` | 不抢焦点 + 系统材质，纯 AppKit 手搭 |
| 输入框 | NSTextView 包装（零内边距） | SwiftUI TextEditor 内边距不可控，占位文字会错位 |
| 设置窗口 | NavigationSplitView + Form(.grouped) | 侧边栏导航 + Esc 关闭，开发效率高 |
| 历史存储 | JSON 文件 | 无依赖；5000 条内读写无压力，可平迁 SQLite |
| API Key 存储 | Keychain（`SecItem*` 封装） | 明文落盘不可接受 |
| HTTP | `URLSession` async/await | 系统自带 |
| TTS | `AVSpeechSynthesizer` + Azure REST | 覆盖免费与微软官方两条路 |
| 本地化 | 10 个 lproj，中文 key 直查 Localizable.strings | SwiftUI 字面量与 NSLocalizedString 双通道同表 |

### 6.3 核心接口（现状）

```swift
// 翻译服务统一协议（source 为 nil 时各服务自动检测源语言）
protocol TranslationService: Sendable {
    var displayName: String { get }
    func translate(_ text: String, from source: String?, to target: String) async throws -> String
}

// TTS 统一协议
@MainActor
protocol SpeechService {
    func speak(_ text: String, language: String) async throws
    func stop()
}

// 「翻译为」清单条目：第 1 条是固定默认槽，其余为快捷键预设
struct TranslateTarget: Codable, Equatable, Identifiable {
    var id: String            // 默认槽稳定 id = "default"
    var language: String      // 目标语言代码（zh / en / ja…）
    var hotkey: Shortcut      // isEmpty = 无快捷键（允许清空）
}

// 历史记录（星标 = 词典条目，interpretation 为 AI 解读）
struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let date: Date
    let sourceText: String
    var resultText: String    // 原地重翻就更新
    let targetLang: String
    var service: String       // 含模型名，如 "Ollama · qwen2.5"
    var isStarred: Bool
    var interpretation: String?
}

// 逐句对照条目（输入面板详细模式）
struct SentencePair: Identifiable {
    let id: Int
    let source: String
    var translation: String?
}
```

### 6.4 目录结构

```
TLKit/
├── project.yml               # XcodeGen 工程定义
├── scripts/                  # build-release.sh（官网版）/ build-appstore.sh（MAS 版）/ 图标生成
├── Sources/TLKit/
│   ├── App/                  // 入口、菜单栏（状态项看门狗/屏外缓解）、TranslationController 流程中枢
│   ├── Hotkey/               // 多键注册管理（清单条目 ID 作 key）
│   ├── Selection/            // 模拟 ⌘C 通道、剪贴板备份还原
│   ├── Translation/          // 协议 + 系统 + 百度智能云 + OpenAICompat(Ollama)
│   ├── Speech/               // 协议 + 系统 + Azure、声音选择与回退
│   ├── History/              // HistoryStore（统计/导出）、DictionaryInterpreter
│   ├── Settings/             // 设置窗口（侧边栏 7 页签、快捷键录制控件）
│   ├── Support/              // KeychainStore、ConfigStore、权限引导、外观、本地化、语言目录
│   ├── UI/                   // BubblePanel、InputPanel、HistoryWindow、ToolWindow、TLStyle
│   └── Resources/            // Info.plist、entitlements×2、PrivacyInfo.xcprivacy、图标、10×lproj
├── Tests/TLKitTests/         # 单元测试（纯逻辑文件直编入测试目标）
├── docs/design.md            # 本文档
├── PRIVACY.md                # 隐私说明（上架材料同源）
└── README.md
```

## 7. 发行、签名与沙盒

| 渠道 | 签名 | 沙盒 | 差异 |
|---|---|---|---|
| Mac App Store（免费） | 3rd Party Mac Developer 证书 | 是 | 默认输入面板取词；用户自行授予辅助功能权限后划词翻译自动解锁（不申请、不引导、不宣传）；UI 不出现「OpenAI」字样 |
| 官网版（官网 / GitHub Releases） | Developer ID + 公证 | 否 | 功能最完整：划词气泡 + 权限引导 |

两渠道共用同一份代码，通过 `APP_STORE` 编译宏（`#if APP_STORE`）+ 两份 entitlements 文件切换：App Store 版含 `com.apple.security.app-sandbox` 与 `network.client`，官网版不含沙盒。「关于」页的渠道标识（App Store / 官网版）也由该宏决定。

**构建体系：**

- XcodeGen 生成工程（`project.yml` 文本化），Swift 6.0，部署目标 macOS 14.0，arm64 + x86_64 通用
- Release 开启 hardened runtime；官网版 Developer ID 签名 + 公证（notarytool，zip 提交，dmg 装订）
- 签名凭证优先读环境变量（`APPLE_DEV_TEAM_ID` / `APPLE_DEV_SIGING_NAME` / `APPLE_DEV_PASSWORD` / `APPLE_DEV_APPLE_ID`），未注入时回退 1Password CLI（`op read`，非交互 shell 授权会超时），脚本不落明文
- 包含 `PrivacyInfo.xcprivacy`（MAS 硬性要求）
- 脚本：`build-release.sh`（官网版 dmg）与 `build-appstore.sh`（archive → productbuild/productsign → pkg → Transporter 上传）

**App Store 审核相关：**

- App Privacy 声明：不收集任何数据（Data Not Collected）。
- BYOK 工具，审核备注提供测试凭据与三服务配置说明。
- 无账号、无内购、无第三方 SDK。

## 8. 权限与隐私

| 权限 | 用途 | 触发时机 |
|---|---|---|
| 辅助功能（Accessibility） | 模拟 ⌘C 取词 | 官网版：首次触发快捷键时引导授权（可「不再提醒」）；商店版：不申请不引导，用户自行授予后启用 |
| 网络出站 | 调用用户配置的翻译 API / TTS | 仅翻译与朗读时 |

- 不收集任何遥测、崩溃上报、埋点（统计页数字全部从本地历史现算）。
- API Key 存 Keychain，配置文件与 UserDefaults 中不出现明文。
- 使用 Ollama 时可做到完全无外网流量。
- 完整隐私说明见仓库根目录 `PRIVACY.md`。

## 9. 错误处理总表

| 场景 | 表现 |
|---|---|
| 未授予辅助功能权限（官网版） | 气泡提示 + "打开系统设置"按钮（可「不再提醒」） |
| 未授予辅助功能权限（商店版） | 快捷键直接打开输入面板，无任何权限提示 |
| 未检测到选中文字 | 自动弹出输入翻译面板 |
| 激活服务未配置完整 | 气泡/面板提示"请先在设置中配置 {服务名}"，可一键打开设置 |
| API 返回错误（401/403/配额等） | 气泡红字展示服务端错误摘要 |
| 网络超时 | 气泡红字"请求超时" |
| Ollama 未启动 / 模型不存在 | 气泡红字提示检查 `ollama serve` 与模型名 |
| 词典解读生成失败 | 历史详情内联错误文案，不影响条目本身 |
| TTS 失败 | 控制台记录，不阻断译文展示 |
| 开机启动注册失败（如 app 不在 /Applications） | 设置开关自动回退到系统实际状态 |
| macOS 14 状态项被系统泊到屏外 | 启动 3 秒后自动打开一次设置窗口提示 |

## 10. 版本记录

| 版本 | 范围 | 状态 |
|---|---|---|
| v0.1 | 取词通道 + 百度翻译 + 气泡三态 + 菜单栏 + 设置（服务/快捷键） | 已完成 |
| v0.2 | 历史记录全套（存储/窗口/搜索/滚动淘汰）+ 自动消失配置 | 已完成 |
| v0.3 | OpenAI 协议 + Ollama + TTS（系统 + Azure）+ 完整设置页 | 已完成 |
| v0.3.x | 输入翻译面板（Google 式双栏、实时翻译）、简洁/详细双模式逐句对照、语音声音选择、开机启动、侧边栏设置窗、隐私页 | 已完成 |
| v1.0.0 | 上架打磨：版本定版、官网版公证发布、App Store 提审 | 已完成 |
| v1.x | 10 语言本地化、新图标（满出血圆角 icns）、界面语言设置、重启/⌘V/气泡播报修复、macOS 14 适配（图标脱离 asset catalog） | 已完成 |
| v2.0.0 | 翻译为清单（多目标语言独立快捷键）、朗读快捷键全面自定义、历史与统计 + JSON/CSV 导出、星标即词典（AI 解读）、原地重翻、macOS 14 屏外缓解、商店版辅助功能彩蛋 | 进行中 |

## 11. 关键决定记录

| 项 | 结论 |
|---|---|
| 应用名 / Bundle ID | TLKit / `me.ckai.translate` |
| 发行 | Mac App Store + Developer ID 双渠道 |
| 目标语言管理 | 「翻译为」清单：第 1 条默认槽 + 快捷键预设，无「设为默认」按钮（直接编辑默认槽） |
| 朗读快捷键 | 全部可自定义；约定「不加修饰键读译文、⇧ 读原文」 |
| 取词通道 | 模拟 ⌘C 单通道（AX 通道实测兼容面窄，已移除） |
| 商店版划词 | 默认输入面板；用户自行授予辅助功能权限后启用（不申请不引导） |
| 百度服务选型 | 百度智能云机器翻译（OAuth），非开放平台 APP ID 方案 |
| 输入面板布局 | Google 式左右双栏（对比垂直布局后选定） |
| 详细模式形态 | 与简洁模式同窗切换（非独立窗口） |
| 输入面板焦点 | 弹出时激活 TLKit 并自动获焦（否则外部语音输入/输入法无法注入文本），关闭归还焦点 |
| TTS 声音 | 语种不匹配时优雅回退自动选声，不做强制校验 |
| 历史记录 | 默认 500 条（100~5000 可配），滚动淘汰；实时翻译去重追加；星标/解读随条目持久化 |
| 词典解读 | 按已配置完整的 AI 引擎给按钮，与当前激活引擎无关；系统/百度不在其列 |
| TTS 兜底 | 未配置 Azure 时使用系统发音，不阻断功能 |
| macOS 14 状态项 | 系统行为不对抗：看门狗重建 + 屏外时启动提示一次 |

## 附录 A：工程踩坑记录

| 结论 | 出处 |
|---|---|
| Carbon `RegisterEventHotKey` 沙盒内可用且零权限 | `HotkeyManager` 实现与注释 |
| NSPanel 悬浮窗配方：nonactivating + `.popUpMenu` 层级 + `canJoinAllSpaces` + popover 毛玻璃 | `BubblePanel` |
| `NSWindow.delegate` 是 weak，必须强引用 delegate，否则关闭回调不触发 | `BubblePanel` 踩坑注释 |
| 透明标题栏会把指定的 contentView 下挤造成大上边距 → 毛玻璃挂到 `panel.contentView` 铺满 | `InputPanel` 踩坑 |
| SwiftUI TextEditor 内边距不可控导致占位文字错位 → 零内边距 NSTextView 包装 | `InputPanel` PlainTextView |
| 设置窗口配方：侧边栏 NavigationSplitView + 分组表单 + Esc（cancelAction）+ activation policy 切换 | `SettingsView` |
| 敏感 Key 存 Keychain、配置走 config.json、轻量偏好走 UserDefaults | `KeychainStore` / `ConfigStore` |
| 双渠道构建：`APP_STORE` 宏 + 双 entitlements + 两套脚本 + 环境变量凭证（op CLI 兜底） | `project.yml`、`scripts/` |
| `AXIsProcessTrustedWithOptions` 运行时检测权限并弹窗引导授权 | `PermissionGate` |
| XcodeGen 文本化工程、Swift 6.0、hardened runtime 仅 Release | `project.yml` |
| Xcode 26 的 actool 丢弃 .appiconset 位图，macOS 14 解析失败 → 菜单栏图标用裸 PNG、App 图标手工烘焙 icns 覆盖 | `TLKitApp.loadMenuBarIcon`、`scripts/generate-legacy-icns.py` |
| macOS 14 刘海机菜单栏空间不足会静默隐藏状态项（isVisible 说谎、窗口泊在屏外）→ 看门狗 + 屏外启动提示，不对抗 | `TLKitApp` |
| accessory 应用无编辑菜单时所有输入框 ⌘V/⌘C 失效 → 主菜单补编辑菜单走响应链 | `TLKitApp.setupMainMenu` |
| 重启自己不能 openApplication + terminate（只会激活不会新实例）→ 直装版派生延迟 open 子进程，沙盒版 createsNewApplicationInstance | `SettingsView.restartApplication` |
