# TLKit

macOS 极简划词翻译工具。选中文字 → 全局快捷键 → 鼠标旁弹出翻译气泡；无选中时弹出输入翻译面板。

- 纯客户端工具，无自建服务器，仅调用你自己配置的翻译 API
- 菜单栏常驻，无 Dock 图标
- 设计文档：[docs/design.md](docs/design.md)

## 当前版本 v1.0.0（官网版已发布，App Store 版待提审）

已实现：

- 全局快捷键（可自定义，支持单键与组合键；面板可见时再按 = 关闭）
- 取词：模拟 ⌘C + 剪贴板（PostEvent TCC 权限，官网版/沙盒版通用），取词后自动还原剪贴板
- 无选中文字时自动弹出输入翻译面板：Google 式双栏、实时翻译（停顿 0.6s 自动译）、方向交换
- 面板「简洁 / 详细」双模式：详细模式逐句对照翻译，悬停高亮建立译文↔原文映射，支持逐句朗读/复制
- 气泡「详细对照」按钮：选中文字翻译后一键进入逐句对照
- 三种翻译服务：百度智能云机器翻译（OAuth token）/ OpenAI 协议 / 本地 Ollama（App Store 版隐藏 OpenAI 入口），设置内可测试连接
- 气泡三态 + 鼠标附近定位 + 自动消失可配置（悬停暂停）
- 朗读：原文/译文、逐句朗读，语速 0.5x~2.0x 可调；系统声音与 Azure 神经语音均可下拉选声（语种不匹配自动回退）
- 翻译历史：本地存储、搜索、删除/清空、保留条数可配（滚动淘汰）、重新翻译
- 设置：侧边栏五页签（通用/翻译服务/语音与历史/隐私/关于），Esc 关闭，含开机启动、渠道与版本信息
- 三主题外观（跟随系统 / 浅色 / 深色）、权限引导与重启提示、App 图标
- 密钥全部只存 Keychain

路线：v1.0 上架（App Store + Developer ID 双渠道）。

## 开发构建

```bash
xcodegen generate
xcodebuild -project TLKit.xcodeproj -scheme TLKit -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/TLKit.app
```

首次按快捷键会弹辅助功能授权（取词必需）；在「设置…」里选一种服务并填好凭据即可翻译。

## 单元测试

```bash
xcodebuild -project TLKit.xcodeproj -scheme TLKit -configuration Debug test
```

覆盖：URL 编码、快捷键模型、配置往返与缺字段容错、百度旧字段迁移、
历史滚动淘汰、OpenAI 端点归一化。
被测纯逻辑文件直接编入测试目标（不挂 app 宿主）。

## 发布构建

```bash
./scripts/build-release.sh    # 官网版（Developer ID + 公证 → dmg）
./scripts/build-appstore.sh   # App Store 版（沙盒 → pkg，Transporter 上传）
```

签名凭证从 1Password CLI 读取（按需改 vault 路径）。公证凭证首次需跑一次 `./scripts/setup-notary.sh`（Apple ID + App 专用密码，同样经 1Password 注入，存入 Keychain）。App Store 版加 `APP_STORE` 编译宏，
作用是隐藏 OpenAI 协议入口（审核敏感）；取词统一走剪贴板通道，与宏无关。

## 目录结构

```
Sources/TLKit/
├── App/          # 入口、菜单栏、流程中枢
├── Hotkey/       # Carbon 全局热键（支持单键）
├── Selection/    # 剪贴板取词通道
├── Translation/  # 服务协议 + 百度智能云 + OpenAI 协议/Ollama
├── History/      # 本地历史记录
├── Speech/       # TTS（系统语音 / Azure，语速可调）
├── UI/           # 气泡、输入面板、历史窗口、设计令牌
├── Settings/     # 设置窗口、快捷键录制控件
├── Support/      # 配置、Keychain、权限引导、外观管理
└── Resources/    # Info.plist、entitlements×2、PrivacyInfo、AppIcon
```
