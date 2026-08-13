# TLKit 设计文档

TLKit = Translate / Language Kit，macOS 极简划词翻译工具。本文档描述**当前已实现的架构**。

| 项目 | 说明 |
|---|---|
| 应用名 | TLKit |
| Bundle ID | `me.ckai.translate` |
| 当前版本 | v1.0.0（官网版已发布，App Store 版待提审） |
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
按下全局快捷键（默认 ⌥D，可自定义）
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
调用当前激活的翻译服务（百度智能云 / AI 大模型 / Ollama）
        │
   ┌────┴────┐
  成功       失败 ──▶ 气泡显示错误原因（红字）
   ▼
气泡展示：原文（灰色小字）+ 译文 + 工具条
（详细对照 / 语速 / 朗读原文 / 复制 / 服务标识）
写入本地历史记录
        │
        ▼
消失：点击其他窗口 / Esc / 自动消失倒计时（悬停暂停、可配置）
```

气泡工具条的「详细对照」按钮把原文送进翻译面板的**详细模式**（逐句对照，见 4.5）。

## 4. 功能详细说明

### 4.1 菜单栏常驻

- 启动后仅在菜单栏显示图标（SF Symbol `character.book.closed`，模板渲染，跟随系统深浅色）。
- 点击图标展开菜单：

| 菜单项 | 说明 |
|---|---|
| 输入翻译 | 打开输入翻译面板 |
| 翻译历史… | 打开历史窗口 |
| 设置… | 打开设置窗口 |
| 退出 TLKit | 退出应用 |

- 菜单项不标注快捷键（菜单栏内的 ⌘ 标注仅在菜单展开时有效，展示会造成歧义）。
- 无 Dock 图标，无主窗口。`Info.plist` 设置 `LSUIElement = true`。

### 4.2 划词取词

- **单一通道：模拟 ⌘C + 剪贴板**（直装与沙盒实测均可用；早期设计的 AX 通道已移除）。
  备份当前剪贴板 → `CGEvent` 模拟 ⌘C → 轮询 `NSPasteboard.changeCount` 直到变化（上限 1 秒）→ 读取纯文本 → 流程结束后还原剪贴板。
- 需要**辅助功能**权限（PostEvent）；未授权时气泡引导用户前往"系统设置 → 隐私与安全性 → 辅助功能"。
- 边界情况：
  - 超时未取到文字 → 视为"无选中内容"，弹出输入翻译面板。
  - 取到的文本超过 3000 字符 → 截断并标注"已截断"。
- 剪贴板还原：逐 item 备份全部类型数据（文本、图片、文件 URL 等），原样写回；个别特殊类型可能无法完美还原，属已知限制。

### 4.3 全局快捷键（可自定义）

- 默认：⌥D。支持组合键与单键（如 F14）。
- 设置页提供**快捷键录制控件**：点击后按下新组合即录入。
- **toggle 语义**：气泡或输入面板可见时再按快捷键 = 关闭，不重复触发。
- 存储：修饰键掩码（Carbon mask）+ keyCode 存入 config.json，应用启动与修改时重新注册（Carbon `RegisterEventHotKey`，沙盒内可用且零额外权限）。

### 4.4 翻译气泡（快速模式）

**外观（遵循 HIG）：**

- 无边框圆角卡片，`NSVisualEffectView(.popover)` 毛玻璃，跟随系统深浅色。
- 宽度 380pt，高度自适应（上限约 400pt），超出可滚动。
- 内容自上而下：
  1. 原文：次要色、小号字体，最多 3 行，溢出省略。
  2. 译文：正文主内容，可滚动、可选中复制。
  3. 底部工具条：服务标识（如"TLKit × Ollama · qwen2.5"）+ 详细对照 / 朗读速度 / 朗读原文 / 复制译文图标按钮。
  4. 语速滑条（0.5x~2.0x，按需展开）。

**行为：**

- 位置：鼠标点附近；下方空间不足则置于上方；超出屏幕边缘时收回屏幕内。
- `NSPanel` + `nonactivatingPanel` + `.popUpMenu` 层级：弹出**不抢走**当前应用的焦点。
- 三态：加载中 / 结果 / 错误（红色文字说明原因）。
- Esc、点击其他窗口（本应用与其他应用均监听）关闭；结果态自动消失倒计时可配置（悬停暂停）。
- 面板实现要点与踩坑记录见附录 A。

### 4.5 输入翻译面板（简洁 / 详细双模式）

无选中文字时的主翻译界面，类 Google 翻译的布局，居中浮窗。

**通用：**

- 顶栏：源语言 ⇄ 目标语言（可交换方向）+「简洁 | 详细」分段切换。
- 底栏：`TLKit × {服务名}` + 快捷键提示（⌘Enter 立即翻译 · Esc 关闭）。
- 面板弹出时**激活 TLKit**（外部输入工具——语音输入、输入法——只会把文本送给活跃应用）；关闭时把焦点归还给原前台应用（仅当用户期间未自行切换应用）。
- 输入区为零内边距的 NSTextView 包装（解决占位文字与输入文字错位问题）。

**简洁模式（640×268）：**

- 左右双栏：左栏输入原文，右栏展示译文。
- 实时翻译：输入停顿 0.6s 自动翻译；⌘Enter 立即触发；清空输入清空结果。
- 左栏工具：朗读原文、清空；右栏工具：复制译文、朗读译文、语速调节。

**详细模式（760×520，逐句对照）：**

- 原文按句拆分（CJK 标点直接切；拉丁句号仅在后随空白时切，避免切断小数/缩写；超过 40 句退化为整段一条）。
- 逐句并发翻译（上限 4 路），每句一张卡片：原文在上（次要层级）、译文在下。
- **悬停映射**：鼠标悬停任一卡片整卡高亮（accent 色 12% 透明度），建立译文 ↔ 原文的视觉对应。
- 悬停时出现句子工具条：朗读这句原文 / 朗读这句译文 / 复制这句译文。
- 交换语言方向会整体重译。

### 4.6 翻译服务

统一服务接口（`TranslationService`），同一时间只有一个**激活服务**，在设置中切换。目标语言为下拉选择（常用 10 语种 + 自定义代码）。每个外部服务在设置中都有「测试连接」按钮（真实发一次 "Hello" 的翻译请求，Azure 为一次语音合成）。

#### 百度智能云机器翻译（默认服务）

- 凭证：**API Key + Secret Key**（百度智能云控制台创建应用获得；不是翻译开放平台的 APP ID 那套）。
- 协议：OAuth2 client_credentials 获取 token（缓存 30 天）→ `POST /rpc/2.0/mt/texttrans/v1`。
- 设置页对服务归属与凭证类型有明确说明文案，避免与开放平台混淆。

#### AI 大模型（OpenAI 兼容格式）

- 配置项：Base URL、API Key、模型名。
- 协议：标准 `POST /chat/completions`，兼容一切 OpenAI 格式服务（DeepSeek、Moonshot、智谱、OpenAI 官方等）。
- 系统提示词在设置页**只读可见**（"你是一个翻译引擎。把用户发送的文本翻译成{目标语言}。只输出译文…"）。
- 服务展示名带模型名（如 "AI · deepseek-chat"），气泡底栏与历史记录可见。

#### Ollama（本地模型）

- 配置项：主机地址（默认 `http://localhost:11434`）、模型名。
- 复用 OpenAI 协议客户端，仅界面上作为独立条目；无 Key 需求，全程本机流量。

### 4.7 TTS 朗读

- 触发点：气泡朗读**原文**（自动检测语种）；输入面板可分别朗读原文/译文；详细模式支持逐句朗读；历史详情可朗读原文/译文。
- 语速：0.5x~2.0x 可调（气泡与面板内嵌滑条），全局生效。
- 供应商（设置中选其一）：

| 供应商 | 配置 | 说明 |
|---|---|---|
| 系统发音 | 声音可下拉选择（本机已装、按语种过滤）+ 试听 | `AVSpeechSynthesizer`，免费离线，默认选项 |
| Azure Speech | Key + Region + 神经语音可选（晓晓/云希/Jenny/Guy 等） | 官方 REST API 合成 mp3 播放 |

- **声音回退规则**：所选声音语种与朗读文本不一致时，自动回退为按文本语言选声（优雅降级，不出怪腔）。
- Azure 未配置完整时自动回退系统发音；播放中再次点击 = 停止；面板/气泡关闭时自动停止。

### 4.8 翻译历史（本地）

- 每次翻译成功自动写入：时间、原文、译文、目标语言、所用服务（含模型名）。
- 输入面板实时翻译走**去重追加**（同一文本连续输入只更新最新一条，不刷屏）。
- 存储：`Application Support/TLKit/history.json`（MAS 版位于沙盒 Container 内），纯本地。
- **容量设置**：保留条数 100 ~ 5000 可配，默认 500，超出滚动淘汰最旧记录。
- 历史窗口（菜单栏 → 翻译历史…）：
  - 左侧列表：时间 + 原文摘要；顶部搜索框按原文/译文过滤。
  - 右侧详情：完整原文 + 译文 + 朗读 + 复制 +「重新翻译」（用当前激活服务再翻一次）。
  - 操作：删除单条、清空全部（二次确认）。

### 4.9 设置窗口

采用**侧边栏导航（NavigationSplitView）+ 分组表单**的成熟模式，5 个页签：

| 页签 | 内容 |
|---|---|
| 通用 | 开机启动（SMAppService 登录项）、主题（跟随系统/浅色/深色）、快捷键录制、气泡自动消失时间、外观模式；辅助功能权限状态与授权引导 |
| 翻译服务 | 激活服务选择、目标语言下拉、各服务凭证配置、服务说明文案、测试连接按钮、模型服务提示词只读展示 |
| 语音与历史 | TTS 供应商、系统声音选择 + 试听、Azure 区域/密钥/神经语音、历史保留条数、清空历史 |
| 隐私 | 数据去向与权限说明的精简视图（完整版见仓库 PRIVACY.md） |
| 关于 | 应用图标、版本号 + build、分发渠道（App Store / 官网版，编译期宏区分）、联系方式 |

**窗口行为：**

- Esc 关闭（关闭按钮绑定 `.keyboardShortcut(.cancelAction)`）。
- 打开时 `NSApp.setActivationPolicy(.regular)`（临时获得 Dock 图标与标准窗口行为），关闭时回 `.accessory`。
- 敏感项（API Key）使用 SecureField，密钥只存 Keychain，配置文件与 UserDefaults 中不出现明文。

## 5. HIG 合规要点

1. 菜单栏图标使用 SF Symbols 模板图，自动适配深浅色与辅助功能对比度。
2. 颜色全部使用语义色（`.primary` / `.secondary` / `.quaternary` 等），不写死色值，原生支持深色模式。
3. 气泡窗口不激活、不抢焦点，符合"辅助浮层"定位；输入面板因需要接受外部输入而主动激活，关闭归还焦点。
4. 所有图标按钮提供 VoiceOver 标签、提示（tooltip）与约 28pt 命中区。
5. 键盘可达：设置与历史窗口支持标准 Tab 导航、Esc 关闭。
6. 间距遵循 8pt 栅格，圆角/字号集中于设计令牌（`TLStyle`）。

## 6. 技术架构

### 6.1 模块划分

```
┌─────────────────────────────────────────────────┐
│                     App 壳层                     │
│   MenuBarExtra · 生命周期 · TranslationController│
├──────────┬──────────┬──────────┬────────────────┤
│ Hotkey   │Selection │Translate │     Speech     │
│ Carbon   │模拟 ⌘C   │服务协议   │ 系统/Azure TTS │
│ 录制/注册 │剪贴板备份 │百度智能云 │ 声音选择/回退  │
│          │还原      │OpenAI/   │                │
│          │          │Ollama    │                │
├──────────┴──────────┴──────────┴────────────────┤
│ ConfigStore（config.json · 缺字段容错）           │
│ HistoryStore（JSON · 滚动淘汰 · 去重追加）        │
│ KeychainStore（SecItem 封装）                    │
├─────────────────────────────────────────────────┤
│                      UI 层                       │
│ BubblePanel · InputPanel(简洁/详细) ·            │
│ SettingsWindow · HistoryWindow · TLStyle 令牌    │
└─────────────────────────────────────────────────┘
```

`TranslationController` 是流程中枢：快捷键 → 权限 → 取词 → 翻译 → 气泡 / 输入面板调度。

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

### 6.3 核心接口（现状）

```swift
// 翻译服务统一协议
protocol TranslationService: Sendable {
    var displayName: String { get }
    func translate(_ text: String, to target: String) async throws -> String
}

// TTS 统一协议
@MainActor
protocol SpeechService {
    func speak(_ text: String, language: String) async throws
    func stop()
}

// 历史记录
struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let date: Date
    let sourceText: String
    let resultText: String
    let targetLang: String
    let service: String      // 含模型名，如 "Ollama · qwen2.5"
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
├── scripts/                  # build-release.sh（官网版）/ build-appstore.sh（MAS 版）
├── Sources/TLKit/
│   ├── App/                  // 入口、菜单栏、TranslationController 流程中枢
│   ├── Hotkey/               // 录制控件、注册管理
│   ├── Selection/            // 模拟 ⌘C 通道、剪贴板备份还原
│   ├── Translation/          // 协议 + 百度智能云 + OpenAICompat(Ollama)
│   ├── Speech/               // 协议 + 系统 + Azure、声音选择与回退
│   ├── History/              // HistoryStore
│   ├── Settings/             // 设置窗口（侧边栏 5 页签）
│   ├── Support/              // KeychainStore、ConfigStore、权限引导、外观
│   ├── UI/                   // BubblePanel、InputPanel、HistoryWindow、TLStyle
│   └── Resources/            // Info.plist、entitlements×2、PrivacyInfo.xcprivacy、图标
├── Tests/TLKitTests/         # 单元测试（纯逻辑文件直编入测试目标）
├── docs/design.md            # 本文档
├── PRIVACY.md                # 隐私说明（上架材料同源）
└── README.md
```

## 7. 发行、签名与沙盒

| 渠道 | 签名 | 沙盒 | 差异 |
|---|---|---|---|
| Mac App Store（免费） | Mac App Store 证书 | 是 | 与官网版功能一致，仅 UI 文案避开敏感词 |
| 官网版（官网 / GitHub Releases） | Developer ID + 公证 | 否 | 功能最完整 |

两渠道共用同一份代码，通过 `APP_STORE` 编译宏（`#if APP_STORE`）+ 两份 entitlements 文件切换：App Store 版含 `com.apple.security.app-sandbox` 与 `network.client`，官网版不含沙盒。「关于」页的渠道标识（App Store / 官网版）也由该宏决定。

**构建体系：**

- XcodeGen 生成工程（`project.yml` 文本化），Swift 6.0，部署目标 macOS 14.0，arm64 + x86_64 通用
- Release 开启 hardened runtime；官网版 Developer ID 签名 + 公证（notarytool，zip 提交，dmg 装订）
- 签名凭证经 1Password CLI（`op read`）注入，脚本不落明文
- 包含 `PrivacyInfo.xcprivacy`（MAS 硬性要求）
- 脚本：`build-release.sh`（官网版 dmg）与 `build-appstore.sh`（archive → export → pkg → Transporter 上传）

**App Store 审核相关：**

- App Privacy 声明：不收集任何数据（Data Not Collected）。
- 辅助功能权限需在审核备注中说明用途（读取用户选中文本用于翻译）。
- 无账号、无内购、无第三方 SDK。

## 8. 权限与隐私

| 权限 | 用途 | 触发时机 |
|---|---|---|
| 辅助功能（Accessibility） | 模拟 ⌘C 取词 | 首次触发快捷键时引导授权 |
| 网络出站 | 调用用户配置的翻译 API / TTS | 仅翻译与朗读时 |

- 不收集任何遥测、崩溃上报、埋点。
- API Key 存 Keychain，配置文件与 UserDefaults 中不出现明文。
- 使用 Ollama 时可做到完全无外网流量。
- 完整隐私说明见仓库根目录 `PRIVACY.md`。

## 9. 错误处理总表

| 场景 | 表现 |
|---|---|
| 未授予辅助功能权限 | 气泡提示 + "打开系统设置"按钮 |
| 未检测到选中文字 | 自动弹出输入翻译面板 |
| 激活服务未配置完整 | 气泡提示"请先在设置中配置 {服务名}" |
| API 返回错误（401/403/配额等） | 气泡红字展示服务端错误摘要 |
| 网络超时 | 气泡红字"请求超时" |
| Ollama 未启动 / 模型不存在 | 气泡红字提示检查 `ollama serve` 与模型名 |
| TTS 失败 | 控制台记录，不阻断译文展示 |
| 开机启动注册失败（如 app 不在 /Applications） | 设置开关自动回退到系统实际状态 |

## 10. 版本记录

| 版本 | 范围 | 状态 |
|---|---|---|
| v0.1 | 取词通道 + 百度翻译 + 气泡三态 + 菜单栏 + 设置（服务/快捷键） | 已完成 |
| v0.2 | 历史记录全套（存储/窗口/搜索/滚动淘汰）+ 自动消失配置 | 已完成 |
| v0.3 | OpenAI 协议 + Ollama + TTS（系统 + Azure）+ 完整设置页 | 已完成 |
| v0.3.x | 输入翻译面板（Google 式双栏、实时翻译）、简洁/详细双模式逐句对照、语音声音选择、开机启动、侧边栏设置窗、隐私页 | 已完成 |
| v1.0.0 | 上架打磨：版本定版、官网版公证发布、App Store 提审 | 进行中 |

## 11. 关键决定记录

| 项 | 结论 |
|---|---|
| 应用名 / Bundle ID | TLKit / `me.ckai.translate` |
| 发行 | Mac App Store + Developer ID 双渠道 |
| 默认快捷键 | ⌥D（可改，支持单键） |
| 取词通道 | 模拟 ⌘C 单通道（AX 通道实测兼容面窄，已移除） |
| 百度服务选型 | 百度智能云机器翻译（OAuth），非开放平台 APP ID 方案 |
| 输入面板布局 | Google 式左右双栏（对比垂直布局后选定） |
| 详细模式形态 | 与简洁模式同窗切换（非独立窗口） |
| 输入面板焦点 | 弹出时激活 TLKit（否则外部语音输入/输入法无法注入文本），关闭归还焦点 |
| TTS 声音 | 语种不匹配时优雅回退自动选声，不做强制校验 |
| 历史记录 | 默认 500 条（100~5000 可配），滚动淘汰；实时翻译去重追加 |
| TTS 兜底 | 未配置 Azure 时使用系统发音，不阻断功能 |

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
| 双渠道构建：`APP_STORE` 宏 + 双 entitlements + 两套脚本 + 1Password CLI 凭证 | `project.yml`、`scripts/` |
| `AXIsProcessTrustedWithOptions` 运行时检测权限并弹窗引导授权 | `PermissionGate` |
| XcodeGen 文本化工程、Swift 6.0、hardened runtime 仅 Release | `project.yml` |
