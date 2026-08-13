# TLKit

macOS 上的划词翻译小工具。选中文字，按个快捷键，译文出现在鼠标旁边；没选中文字，就弹出输入框手动翻。

## 为什么做这个

我英文不算好，看英文文档、论文、网页时经常要临时查一下词。试过的翻译工具要么太臃肿，要么得装一堆插件，都不太顺手。于是给自己写了一个：没有后台服务器，数据全在本地，只调你填的翻译 API，除此之外什么都不干。

## 能做什么

- 划词翻译：全局快捷键（默认 `⌥D`）唤起，气泡贴着鼠标出现，不抢当前窗口焦点
- 输入翻译：没有选中文字时弹出输入面板，左右双栏，边打边译
- 三种翻译服务：百度翻译、AI 大模型（DeepSeek / 智谱 / Kimi 等）、Ollama 本地模型
- 逐句对照：长文按句拆开翻译，悬停高亮对应关系，还能逐句朗读
- 朗读：原文译文都能读，语速可调，系统声音或 Azure
- 历史记录：本地保存，可搜索、删除、重新翻译
- 菜单栏常驻，无 Dock 图标

## 安装

- **App Store**：搜索 TLKit
- **官网版**：在 [Releases](https://github.com/gccyk-futur/translate-lckit/releases) 下 dmg，拖进「应用程序」即可（已公证）

装好后打开「设置 → 翻译服务」，挑一个服务填好凭据就能用了。首次使用会请求辅助功能权限，用于模拟 `⌘C` 取词。

## 翻译服务

| 服务 | 需要填什么 |
|---|---|
| 百度翻译 | API Key + Secret Key（百度智能云控制台） |
| AI 大模型 | Base URL + 模型名 + API Key，兼容 Chat Completions 格式 |
| Ollama | 本机地址 + 模型名，文字不出电脑 |

所有密钥都存在 Keychain 里，不写进配置文件。

## 开发构建

```bash
xcodegen generate
xcodebuild -project TLKit.xcodeproj -scheme TLKit -configuration Debug CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/TLKit.app
```

## 测试

```bash
xcodebuild -project TLKit.xcodeproj -scheme TLKit -configuration Debug test
```

## 发布

```bash
./scripts/build-release.sh    # 官网版：Developer ID 签名 + 公证 → dmg
./scripts/build-appstore.sh   # App Store 版：沙盒 → pkg
```

签名凭证通过 1Password CLI 注入，脚本里不落明文。更多实现细节见 [docs/design.md](docs/design.md)。

## 隐私

没有后台服务器，没有埋点和统计，所有数据只存你本机。完整说明见 [PRIVACY.md](PRIVACY.md)。

## License

[MIT](LICENSE)

## 反馈

有 bug 或想法，去 [Issues](https://github.com/gccyk-futur/translate-lckit/issues) 提，我看到会尽量回。这工具主要是我自用，更新跟着自己的需要走，不是高频迭代的项目，所以有些需求可能不会做，先说明。
