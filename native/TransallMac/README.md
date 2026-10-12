# Transall for macOS

Transall 是一个本机文档工作台，用 SwiftUI 编写。界面语言是简体中文。文档处理全部在本机完成。只有翻译会把提取出的文字发给你选的服务商（DeepSeek 或 OpenAI）。

## 功能

- **格式转换**：共 18 条转换路线。在主界面把源格式和目标格式拖进沙漏，再添加文件。
- **PDF 修改**：合并、删页、旋转、裁剪、加水印、查找替换文字。
- **PDF 编辑**：在页面上直接改文字。可以改字体、字号、颜色和位置。编辑由内置的 PDFium 完成，页面不会被转成图片。
- **PDF 翻译**：输出纯译文、双语对照，或保留原版式的译文 PDF。图片里的文字先用 Vision 在本机识别。
- **OCR**：用 Vision 在本机识别文字。
- **Office 转换**：Word、PowerPoint、Excel 转 PDF 或 Markdown。这个功能需要你自己安装 LibreOffice，应用不会自动安装。

任务数据保存在应用的 Application Support 目录里，超过 24 小时自动删除。

### 限制

| 项目 | 上限 |
| --- | ---: |
| 文本、Markdown、HTML 转 PDF；HTML、数据转 Markdown | 合计 20 MB |
| 其他路线 | 合计 250 MB |
| 每个任务的文件数 | 256 个 |

PDF 编辑只支持简单的横排文字。旋转文字、扫描件的文字层、表单里的文字不能编辑。

## 结构

```text
SwiftUI 界面
    ├── PDFKit / Core Graphics：PDF 操作和渲染
    ├── PDFium 8046：PDF 文字编辑（静态链接，见 ThirdParty/PDFium）
    ├── Vision：本机 OCR
    ├── Core Text / 离屏 WebKit：生成可搜索的 PDF
    ├── LibreOffice（可选）：Office 转换
    └── URLSession：DeepSeek / OpenAI 翻译
```

## 开发

需要：

- macOS 14 或更新版本
- Xcode 26.6 或更新版本
- XcodeGen 2.46.0（只在重新生成 Xcode 项目时需要）

在本目录运行：

```bash
swift run TransallMac
```

`project.yml` 是 Xcode 项目的源文件。改了 `project.yml` 之后，用 XcodeGen 重新生成 `Transall.xcodeproj`。

## 测试

```bash
swift test
```

提交前，CI 还会检查代码格式：

```bash
xcrun swift-format lint --strict --recursive --parallel Sources Tests
```

如果只装了 Command Line Tools，没有装完整的 Xcode，`swift test` 可能找不到测试库。这时 `swift build` 仍然可以用。

## 打包上架

上架前要准备的账号、签名和网址，见 [APP_STORE_READINESS.md](APP_STORE_READINESS.md)。

Release 打包时，必须把 `TRANSALL_PRIVACY_POLICY_URL` 设成已发布的隐私政策网址。如果这个值缺失或不是公开的 HTTPS 网址，打包会失败。
