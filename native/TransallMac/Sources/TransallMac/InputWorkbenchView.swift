import SwiftUI

struct InputWorkbenchView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(model.selectedTask.title).font(.headline)
          if model.selectedTask.sources.count > 1 {
            Picker(
              "文件类型",
              selection: Binding(
                get: { model.selection.source ?? model.selectedTask.sources[0] },
                set: { model.selectTask(model.selectedTask, source: $0) }
              )
            ) {
              ForEach(model.selectedTask.sources, id: \.self) { source in
                Text(WorkbenchTask.sourceTitle(source)).tag(source)
              }
            }
            .disabled(!model.canChangeRoute)
          }
          if let route = model.route {
            routeOptions(route).disabled(!model.canEditTaskDraft || model.isImporting)
            if route.source == "image", route.target == "pdf" {
              Text("按文件列表顺序合成一个 PDF。").font(.callout).foregroundStyle(.secondary)
            }
            if route.source == "html" {
              Text(route.target == "pdf" ? "保留样式、表格与内嵌图片；不加载外部资源。" : "提取标题、列表、表格与链接。").font(
                .caption
              ).foregroundStyle(.secondary)
            }
            if route.kind == "office_convert" {
              if OfficeConversionComponent.requiresSetup {
                SettingsLink { Text("启用 Office 转换…") }.font(.caption)
              }
              Text(
                OfficeDocumentConverter.executable == nil
                  ? OfficeDocumentConverter.missingMessage : "使用本机 LibreOffice；多个文件按列表顺序合并输出。"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("接受 \(route.accept)").font(.caption).foregroundStyle(.secondary)
            Text(
              "上限 \(model.inputLimitMB) MB · 每批最多 \(NativeCapabilities.maximumInputFileCount) 个文件"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
      .accessibilityLabel("任务参数")
      Divider()
      HStack {
        TaskActionButtons().labelStyle(.titleAndIcon)
        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .background(TransallTheme.panel)
  }

  @ViewBuilder
  private func routeOptions(_ route: RouteDefinition) -> some View {
    if route.source == "md", route.kind == "text_to_pdf" {
      Text("支持标题、列表、表格、代码和内嵌图片；不加载外部资源。")
        .font(.caption).foregroundStyle(TransallTheme.inkSoft)
    }
    if route.optionPanels.contains("translate") {
      translationOptions
    }

    if route.optionPanels.contains("edit") {
      editOptions
    }

    if route.optionPanels.contains("ocr") {
      ocrOptions(showsOutput: route.target == "ocr")
    }

    if route.optionPanels.contains("advanced"),
      route.optionPanels.contains("translate")
        || (route.optionPanels.contains("edit") && model.options.editAction == "edit")
    {
      Divider().overlay(TransallTheme.line)
      DisclosureGroup("高级参数", isExpanded: $model.showAdvanced) {
        advancedOptions(route)
          .padding(.top, 12)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(TransallTheme.inkSoft)
    }
  }

  private var translationOptions: some View {
    VStack(alignment: .leading, spacing: 11) {
      SectionLabel(text: "翻译设置")
      optionGrid {
        Picker("翻译服务", selection: $model.options.provider) {
          ForEach(model.providers) { provider in
            Text("\(provider.displayName)\(provider.configured ? "" : "（未配置）")")
              .tag(provider.name)
          }
        }
        .controlSize(.small)

        Picker("输出", selection: $model.options.outputMode) {
          Text("保留原版式 PDF").tag("preserve_layout")
          Text("纯译文 PDF").tag("translated")
          Text("双语对照 PDF").tag("bilingual")
        }
        .controlSize(.small)
      }

      optionGrid {
        VStack(alignment: .leading, spacing: 4) {
          Text("源语言").font(.caption)
          TextField("源语言（如 en）", text: $model.options.sourceLanguage)
            .textFieldStyle(.roundedBorder).controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("目标语言").font(.caption)
          TextField("目标语言（如 zh）", text: $model.options.targetLanguage)
            .textFieldStyle(.roundedBorder).controlSize(.small)
        }
      }
      if model.options.outputMode == "preserve_layout" {
        Text("页面背景保存为高清图像，译文可选择；保留页面方向、裁剪和批注。文字放不下时会提示改用纯译文。")
          .font(.caption).foregroundStyle(TransallTheme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }

      Label {
        Text(
          "提取文字会发送给所选服务商；任务文件和结果保存在本机。单次最多 \(PDFTranslationPolicy.maximumPages) 页、\(PDFTranslationPolicy.maximumCharacters.formatted()) 个字符，全文检查通过后才开始请求。"
        )
      } icon: {
        Image(systemName: "network")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var editOptions: some View {
    VStack(alignment: .leading, spacing: 9) {
      SectionLabel(text: "操作")
      Picker("PDF 操作", selection: $model.options.editAction) {
        Text("编辑单个 PDF").tag("edit")
        Text("合并 PDF").tag("merge")
      }
      .pickerStyle(.menu)
      .controlSize(.small)
    }
  }

  private func ocrOptions(showsOutput: Bool) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      SectionLabel(text: "文字识别")
      optionGrid {
        TextField("识别语言，如 zh-Hans,en-US", text: $model.options.ocrLanguage)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        if showsOutput {
          Picker("输出", selection: $model.options.ocrOutputFormat) {
            Text("可搜索 PDF").tag("searchable_pdf")
            Text("纯文本").tag("text")
          }
          .controlSize(.small)
        }
      }
    }
  }

  @ViewBuilder
  private func advancedOptions(_ route: RouteDefinition) -> some View {
    if route.optionPanels.contains("translate") {
      VStack(alignment: .leading, spacing: 10) {
        TextField("术语表：每行一个术语映射", text: $model.options.glossary, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...5)
          .controlSize(.small)
      }
    }

    if route.optionPanels.contains("edit"), model.options.editAction == "edit" {
      LazyVGrid(columns: fieldColumns, alignment: .leading, spacing: 9) {
        compactField("删除页，如 2,4-6", text: $model.options.deletePages)
        compactField("旋转页，如 1,3-5", text: $model.options.rotatePages)
        TextField("旋转角度", value: $model.options.rotateDegrees, format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        compactField("页面顺序，如 3,1,2", text: $model.options.reorderPages)
        compactField("裁剪页，如 1,3-5", text: $model.options.cropPages)
        compactField("裁剪区域 x0,y0,x1,y1", text: $model.options.cropBox)
        compactField("水印文字", text: $model.options.watermark)
        compactField(
          "查找文字",
          text: Binding(
            get: { model.options.replaceFind ?? "" }, set: { model.options.replaceFind = $0 }))
        compactField(
          "替换为（留空则删除）",
          text: Binding(
            get: { model.options.replaceWith ?? "" }, set: { model.options.replaceWith = $0 }))
      }
      if !(model.options.replaceFind ?? "").isEmpty {
        Text("精确匹配单行文字，替换区域为白底。修改页重绘并保留搜索；交互批注不保留。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var fieldColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 170), spacing: 9)]
  }

  private func compactField(_ prompt: String, text: Binding<String>) -> some View {
    TextField(prompt, text: text)
      .textFieldStyle(.roundedBorder)
      .controlSize(.small)
  }

  private func optionGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    LazyVGrid(columns: fieldColumns, alignment: .leading, spacing: 9, content: content)
  }
}
