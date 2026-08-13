# 隐私说明

## 我们收集什么

**什么都不收集。** TLKit 没有后台服务器，不使用任何分析或追踪框架，不统计使用情况。

## 数据存储在哪

所有数据仅存储在你的 Mac 本地：

| 数据 | 位置 | 说明 |
|------|------|------|
| 配置 | `~/Library/Application Support/TLKit/config.json` | JSON 明文，仅本机用户有读取权限 |
| 历史记录 | `~/Library/Application Support/TLKit/history.json` | 最近若干条翻译记录 |
| 密钥 | macOS Keychain | 百度 Secret Key、OpenAI API Key、Azure 订阅密钥，不写入配置文件 |

## 文字和语音的去向

取决于你选择的翻译服务与语音：

- **百度翻译**：待译文字发往百度翻译 API（你配置的账号）。
- **OpenAI 协议**：待译文字发往你配置的 Base URL 对应服务。
- **Ollama**：本地模型，文字完全不出电脑。
- **系统语音**：本机合成，不出电脑。
- **Azure 语音**：待朗读文本发往你配置的 Azure 区域进行合成。

TLKit 仅建立连接和传输数据，不缓存、不记录这些通信内容，你是数据的控制者。

## 权限

TLKit 请求以下系统权限，全部用于核心功能：

| 权限 | 用途 |
|------|------|
| 辅助功能 | 模拟 ⌘C 获取选中文字（划词翻译） |

所有权限均可随时在「系统设置 → 隐私与安全性」中撤销。

## 第三方服务

当你使用百度翻译、OpenAI 协议服务或 Azure 语音时，你与这些服务商的交互受其各自的隐私政策约束。TLKit 仅作为数据传输管道。

## 联系

如有隐私相关问题：

- 信箱：tlkit@ckai.me
- 支持：https://ckai.me/tlkit/support.html
- 隐私政策（线上版）：https://ckai.me/tlkit/privacy.html
