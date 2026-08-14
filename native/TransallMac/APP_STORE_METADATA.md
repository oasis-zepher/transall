# App Store metadata draft

## Product

| Field | Draft |
| --- | --- |
| Name | Transall |
| Subtitle | 本地 PDF 与文档工作台 |
| Primary category | Productivity |
| Secondary category | Utilities |
| Version | 1.0.0 |
| SKU | TRANSALL-MAC-001 |
| Business model | One-time paid download; no In-App Purchases in 1.0 |
| Bundle ID | `com.transall.mac` is provisional; replace after choosing and registering a final unique identifier |
| Seller | Individual developer's verified legal name; `Zephyr` remains the brand |
| Copyright | Replace with the verified individual rights-holder name before submission |
| Support URL | Publish `store/support-site/` and use its root HTTPS URL |
| Privacy policy URL | Use the published `/privacy` URL |

## Promotional text

在 Mac 上整理、识别、提取和翻译 PDF。常规处理全部在本机完成，只有用户主动翻译时才会把提取出的文字发送给所选服务商。

## Description

Transall 是一款原生 macOS 文档工作台，适合处理研究资料、扫描件和日常 PDF。

- 合并、删除、旋转、重排和裁剪 PDF 页面
- 为 PDF 添加文字水印并预览结果
- 使用 Apple Vision 在本机进行 OCR
- 将图片、Markdown、HTML 和文本数据生成 PDF
- 从 PDF 或图片提取文字并保存为 Markdown
- 使用用户自己的 DeepSeek 或 OpenAI API Key 翻译 PDF
- 在任务运行前检查文件、参数和翻译服务配置
- 支持任务取消、恢复、日志和本地任务数据删除

Transall 不要求注册账号，不含广告、分析统计或跨 App 跟踪。API Key 保存在 macOS 钥匙串。除用户主动执行翻译外，文档内容不会发送给外部服务。

## Keywords

PDF,OCR,文档,翻译,扫描,Markdown,合并,水印

## Age rating draft

All content descriptors: None. Expected rating: 4+. Confirm in App Store Connect because Apple owns the final questionnaire and rating.

## App Privacy draft

| Question | Draft answer | Evidence |
| --- | --- | --- |
| Data used to track users | No | No advertising, analytics, or tracking SDK |
| User Content → Other User Content | Collected for App Functionality | Extracted translation text is sent to DeepSeek or OpenAI and may be retained by the provider |
| Data linked to user | Conservatively answer Yes for translated user content | The user's provider API key can associate requests with the provider account |
| Developer-controlled collection | No | No Transall server or telemetry service |
| Credentials | Not collected by developer; stored locally | macOS Keychain; sent only as authorization to the selected provider |
| Local task retention | Not App Privacy “collection” | On-device App container, next-launch cleanup after 24 hours plus manual deletion |
| Tracking | No | Translation content is not used by Transall for advertising or tracking |

This draft deliberately does not claim “Data Not Collected”: Apple requires disclosure of data collected by third-party partners, and translation is a normal product feature. Review the providers' current retention and account-linking terms immediately before submission.

## Screenshot checklist

1. Empty document workbench with the circular route selector.
2. PDF editing options with selected files.
3. OCR result with page previews and logs.
4. Translation disclosure and provider selector.
5. Keychain-backed provider settings.

Use the synthetic files in `output/pdf/review-samples/` and a currently accepted 16:10 macOS screenshot size. Do not show API keys, personal filenames, or third-party document content. Follow `store/SCREENSHOT_PLAN.md`.

## Review information

Use `store/APP_REVIEW_NOTES.md`. A rate-limited translation API key must be entered only in App Store Connect review information, never committed here.
