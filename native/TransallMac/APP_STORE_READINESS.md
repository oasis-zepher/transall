# 上架准备

结论：应用本身可以打包。还有 7 件事要先完成，都需要你本人操作或做决定。

## 待办

| 事项 | 要做什么 |
| --- | --- |
| 开发者账号 | 完成身份验证，支付 Apple Developer Program 年费，等待个人会员生效。卖家名称是验证过的法定姓名，品牌名仍是 `Zephyr`。 |
| 签名 | 设置 Team 和最终的 Bundle ID。创建 Mac App Store 分发证书和描述文件。在签名后的版本里确认钥匙串能正常读写。本机目前没有可用的签名证书。 |
| 协议 | 账号持有人接受付费应用协议，并填写税务和银行信息。 |
| 网址 | 替换支持网站里的姓名、域名和邮箱占位符。运行 `npm run build:publication` 并发布网站。把 `/privacy` 页面的网址填进 `TRANSALL_PRIVACY_POLICY_URL`。 |
| App Store Connect | 创建应用记录。填写年龄分级、分类、价格、地区、DSA 商户身份、描述、截图和隐私问卷。 |
| 审核用密钥 | 提供一个新的、有限额的 DeepSeek 或 OpenAI 密钥，让审核人员能测试翻译。 |
| CI | 推送全部提交，确认 GitHub Actions 的三个任务都通过。 |

## 打包要点

- 应用里没有 Python、LibreOffice、Chromium、OCRmyPDF、Tesseract 或 BabelDOC。这些只属于浏览器版。
- 应用静态链接了 PDFium 8046（BSD 许可）。它的许可声明在 `Resources/PDFium-Licenses`，会一起打进应用包。
- Debug 和 Release 都在 App Sandbox 里运行。
- 应用只声明了简体中文（`zh-Hans`）。

## 上架材料

- [个人开发者注册](../../store/INDIVIDUAL_ENROLLMENT.md)
- [付费应用提交清单](../../store/PAID_APP_SUBMISSION_CHECKLIST.md)
- [审核说明](../../store/APP_REVIEW_NOTES.md)
- [截图计划](../../store/SCREENSHOT_PLAN.md)
- [支持网站](../../store/support-site/)
