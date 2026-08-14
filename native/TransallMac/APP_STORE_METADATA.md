# App Store metadata draft

## Product

| Field | Draft |
| --- | --- |
| Name | Transall |
| Subtitle | 本地 PDF 与文档工作台 |
| Primary category | Productivity |
| Secondary category | Utilities |
| Copyright | Replace with the publisher's legal name before submission |
| Support URL | Required from publisher |
| Privacy policy URL | Publish `docs/PRIVACY.md` at a stable HTTPS URL |

## Promotional text

在 Mac 上整理、识别、提取和翻译 PDF。常规处理全部在本机完成，只有用户主动翻译时才会把提取出的文字发送给所选服务商。

## Description

Transall 是一款原生 macOS 文档工作台，适合处理研究资料、扫描件和日常 PDF。

- 合并、删除、旋转、重排和裁剪 PDF 页面
- 为 PDF 添加文字水印并预览结果
- 使用 Apple Vision 在本机进行 OCR
- 将图片、Markdown、HTML 和文本数据生成 PDF
- 从 PDF 或图片提取 Markdown
- 使用用户自己的 DeepSeek 或 OpenAI API Key 翻译 PDF
- 在任务运行前检查文件、参数和翻译服务配置
- 支持任务取消、恢复、日志和本地任务数据删除

Transall 不要求注册账号，不含广告、分析统计或跨 App 跟踪。API Key 保存在 macOS 钥匙串。除翻译功能外，文档内容不会发送给外部服务。

## Keywords

PDF,OCR,文档,翻译,扫描,Markdown,合并,水印

## Age rating draft

All content descriptors: None. Expected rating: 4+. Confirm in App Store Connect because Apple owns the final questionnaire and rating.

## App Privacy draft

| Question | Draft answer | Evidence |
| --- | --- | --- |
| Data used to track users | No | No advertising or tracking SDK |
| Data linked to the user and collected by developer | No | No developer service or telemetry |
| User content sent off device | Only during an explicit translation task | Sent directly to the user-selected DeepSeek or OpenAI account |
| Credentials | Stored locally | macOS Keychain |
| Local task retention | 24 hours by default | Automatic cleanup plus manual task deletion |

Review the final answers against Apple's current App Privacy definitions before submission.

## Screenshot checklist

1. Empty document workbench with the circular route selector.
2. PDF editing options with selected files.
3. OCR result with page previews and logs.
4. Translation disclosure and provider selector.
5. Keychain-backed provider settings.

Use 16:10 screenshots without API keys, personal filenames, or document content.
