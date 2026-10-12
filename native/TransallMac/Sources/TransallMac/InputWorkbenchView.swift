import SwiftUI

struct InputWorkbenchView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section(model.selectedTask.title) {
        if model.selectedTask.sources.count > 1 {
          optionPicker(
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
        }
      }
      if let route = model.route {
        if route.optionPanels.contains("translate") {
          Section("文字与隐私") {
            Label("提取的文字会发送给所选翻译服务商；原文件和结果保存在本机。", systemImage: "network")
              .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(
              "单次最多 \(PDFTranslationPolicy.maximumPages) 页、\(PDFTranslationPolicy.maximumCharacters.formatted()) 个字符，全文检查通过后才开始请求。"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        if showsAdvanced(route) {
          Section {
            DisclosureGroup("高级选项", isExpanded: $model.showAdvanced) {
              advancedOptions(route)
                .disabled(!model.canEditTaskDraft || model.isImporting)
                .padding(.top, 12)
            }
          }
        }
        Section("文件要求") {
          routeNotice(route)
          Text(
            "接受 \(route.accept) · 上限 \(model.inputLimitMB) MB · 每批最多 \(NativeCapabilities.maximumInputFileCount) 个文件"
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .formStyle(.grouped)
    .controlSize(.regular)
    .scrollContentBackground(.hidden)
    .background(TransallTheme.panel)
    .accessibilityLabel("任务参数")
  }

  private func showsAdvanced(_ route: RouteDefinition) -> Bool {
    route.optionPanels.contains("advanced")
      && (route.optionPanels.contains("translate")
        || (route.optionPanels.contains("edit") && model.options.editAction == "edit"))
  }

  @ViewBuilder
  private func routeOptions(_ route: RouteDefinition) -> some View {
    if route.optionPanels.contains("translate") {
      optionPicker("翻译服务", selection: $model.options.provider) {
        if model.providers.isEmpty {
          ForEach(ProviderCredential.allCases) { provider in
            Text("\(provider.displayName)（正在检查配置）").tag(provider.rawValue)
          }
        }
        ForEach(model.providers) { provider in
          Text(
            "\(provider.displayName)\(provider.authorizationRequired == true ? "（需要授权）" : (provider.configured ? "" : "（未配置）"))"
          ).tag(provider.name)
        }
      }
      languagePicker("原文语言", selection: $model.options.sourceLanguage, allowsAutomatic: true)
      languagePicker("译文语言", selection: $model.options.targetLanguage, allowsAutomatic: false)
      optionPicker("输出内容", selection: $model.options.outputMode) {
        Text("译文 PDF · 保留版式").tag("preserve_layout")
        Text("双语左右对照 · 保留版式").tag("bilingual")
        Text("纯文字译稿 · 重新排版").tag("translated")
      }
      if model.options.outputMode != "translated" {
        Text(
          model.options.outputMode == "bilingual"
            ? "每一页左侧原文、右侧译文，保留双栏、图表与文字位置；预览和下载保持一致。"
            : "保留双栏、图表与文字位置，译文可搜索。文字放不下时保留译文并提示调整。"
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("仅提取文字重新排版，不保留原文图表和布局。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    if route.optionPanels.contains("edit") {
      optionPicker("PDF 操作", selection: $model.options.editAction) {
        Text("编辑单个 PDF").tag("edit")
        Text("合并 PDF").tag("merge")
      }
    }
    if route.optionPanels.contains("ocr") {
      field("识别语言", prompt: "例如 zh-Hans,en-US", text: $model.options.ocrLanguage)
      if route.target == "ocr" {
        optionPicker("输出内容", selection: $model.options.ocrOutputFormat) {
          Text("可搜索 PDF").tag("searchable_pdf")
          Text("纯文本").tag("text")
        }
      }
    }
  }

  @ViewBuilder
  private func advancedOptions(_ route: RouteDefinition) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if route.optionPanels.contains("translate") {
        VStack(alignment: .leading, spacing: 6) {
          Text("术语表").accessibilityHidden(true)
          TextField("每行一个术语映射", text: $model.options.glossary, axis: .vertical)
            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
            .lineLimit(3...6)
            .accessibilityLabel("术语表")
        }
      }
      if route.optionPanels.contains("edit"), model.options.editAction == "edit" {
        SectionLabel(text: "页面操作")
        field("删除页", prompt: "例如 2,4-6", text: $model.options.deletePages)
        field("旋转页", prompt: "例如 1,3-5", text: $model.options.rotatePages)
        VStack(alignment: .leading, spacing: 6) {
          Text("旋转角度").accessibilityHidden(true)
          TextField("旋转角度", value: $model.options.rotateDegrees, format: .number)
            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
            .accessibilityLabel("旋转角度")
        }
        field("页面顺序", prompt: "例如 3,1,2", text: $model.options.reorderPages)
        Divider()
        SectionLabel(text: "裁剪")
        field("裁剪页", prompt: "例如 1,3-5", text: $model.options.cropPages)
        field("裁剪区域", prompt: "x0,y0,x1,y1", text: $model.options.cropBox)
        Divider()
        SectionLabel(text: "水印")
        field("水印文字", prompt: "输入水印内容", text: $model.options.watermark)
        Divider()
        SectionLabel(text: "文字替换")
        field(
          "查找文字", prompt: "精确匹配单行文字",
          text: Binding(
            get: { model.options.replaceFind ?? "" }, set: { model.options.replaceFind = $0 }))
        field(
          "替换为", prompt: "留空则删除",
          text: Binding(
            get: { model.options.replaceWith ?? "" }, set: { model.options.replaceWith = $0 }))
        if !(model.options.replaceFind ?? "").isEmpty {
          Text("替换区域为白底。修改页重绘并保留搜索；交互批注不保留。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func routeNotice(_ route: RouteDefinition) -> some View {
    if route.source == "image", route.target == "pdf" {
      Text("按文件列表顺序合成一个 PDF。").font(.callout)
    }
    if route.source == "html" || (route.source == "md" && route.kind == "text_to_pdf") {
      Text(
        route.target == "pdf"
          ? "保留标题、列表、表格和内嵌图片；不加载外部资源。"
          : "提取标题、列表、表格与链接。"
      )
      .font(.callout).foregroundStyle(.secondary)
    }
    if route.kind == "office_convert" {
      if OfficeConversionComponent.requiresSetup {
        SettingsLink { Text("启用 Office 转换…") }
      }
      Text(
        OfficeDocumentConverter.executable == nil
          ? OfficeDocumentConverter.missingMessage
          : "使用本机 LibreOffice；多个文件按列表顺序合并输出。"
      )
      .font(.callout).foregroundStyle(.secondary)
    }
  }

  private static let translationLanguages: [(code: String, name: String)] = [
    ("zh", "简体中文"), ("zh-Hant", "繁体中文"), ("en", "英语"),
    ("ja", "日语"), ("ko", "韩语"), ("fr", "法语"), ("de", "德语"),
    ("es", "西班牙语"), ("pt", "葡萄牙语"), ("it", "意大利语"),
    ("ru", "俄语"), ("nl", "荷兰语"), ("pl", "波兰语"),
    ("vi", "越南语"), ("th", "泰语"), ("id", "印度尼西亚语"),
    ("tr", "土耳其语"), ("ar", "阿拉伯语"), ("hi", "印地语"),
  ]

  private func languagePicker(
    _ title: String, selection: Binding<String>, allowsAutomatic: Bool
  ) -> some View {
    optionPicker(title, selection: selection) {
      if allowsAutomatic {
        Text("自动识别").tag("auto")
        Divider()
      }
      ForEach(Self.translationLanguages, id: \.code) { language in
        Text(language.name).tag(language.code)
      }
      // Keep older saved language variants selectable without silently changing the job.
      if !Self.translationLanguages.contains(where: { $0.code == selection.wrappedValue }),
        !(allowsAutomatic && selection.wrappedValue == "auto")
      {
        Text(
          Locale(identifier: "zh-Hans").localizedString(forIdentifier: selection.wrappedValue)
            ?? "已保存的语言"
        ).tag(selection.wrappedValue)
      }
    }
  }

  private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).accessibilityHidden(true)
      TextField(title, text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
        .accessibilityLabel(title)
    }
  }

  private func optionPicker<Options: View>(
    _ title: String, selection: Binding<String>, @ViewBuilder options: () -> Options
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).accessibilityHidden(true)
      Picker(title, selection: selection, content: options)
        .labelsHidden().pickerStyle(.menu).accessibilityLabel(title)
    }
  }
}
