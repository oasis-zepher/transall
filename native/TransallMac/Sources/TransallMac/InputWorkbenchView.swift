import SwiftUI
import UniformTypeIdentifiers

private final class InputViewState: ObservableObject {
  @Published var showImporter = false
  @Published var isDropTargeted = false
  var isAppending = false
}

struct InputWorkbenchView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var viewState = InputViewState()

  var body: some View {
    WorkbenchPanel {
      VStack(alignment: .leading, spacing: 16) {
        panelHeader
        fileWell

        if let route = model.route, route.enabled {
          routeOptions(route)
            .disabled(model.isSubmitting)
          actionBar(route)
        } else {
          unavailableHint
        }
      }
    }
    .fileImporter(
      isPresented: $viewState.showImporter,
      allowedContentTypes: allowedContentTypes,
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        let appending = viewState.isAppending
        Task { await model.importDocuments(urls, appending: appending) }
      case .failure(let error): model.errorMessage = error.localizedDescription
      }
    }
  }

  private var panelHeader: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        SectionLabel(text: "Input")
        Text(model.route?.enabled == true ? model.routeTitle : "选择路径后上传")
          .font(.system(.title3, design: .serif, weight: .semibold))
      }
      Spacer()
      Text("\(model.documents.count) FILES")
        .font(.system(.caption2, design: .rounded, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(TransallTheme.muted)
    }
  }

  private var fileWell: some View {
    LazyVStack(spacing: model.documents.isEmpty || model.isImporting ? 7 : 10) {
      if model.isImporting {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在读取文件")
        Text("正在读取文件")
          .font(.callout.weight(.semibold))
        Text("全部文件通过校验后才会加入列表")
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
      } else if model.documents.isEmpty {
        Image(systemName: "doc.badge.plus")
          .font(.title2.weight(.light))
          .foregroundStyle(TransallTheme.accent)
        Text("拖入文件，或点击选择")
          .font(.callout.weight(.semibold))
        Text(fileHint)
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
          .multilineTextAlignment(.center)
      } else {
        ForEach(model.documents) { document in
          HStack(spacing: 10) {
            Image(systemName: "doc.text")
              .foregroundStyle(TransallTheme.source)
            VStack(alignment: .leading, spacing: 2) {
              Text(document.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.name)
              Text(document.formattedSize)
                .font(.caption2)
                .foregroundStyle(TransallTheme.muted)
            }
            Spacer()
            Button {
              model.removeDocument(document)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(TransallTheme.muted)
                .padding(5)
            }
            .buttonStyle(.plain)
            .disabled(inputIsLocked)
            .accessibilityLabel("移除\(document.name)")
          }
        }

        Button("继续添加文件") {
          viewState.isAppending = true
          viewState.showImporter = true
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(inputIsLocked)
      }
    }
    .frame(maxWidth: .infinity, minHeight: model.documents.isEmpty || model.isImporting ? 116 : 76)
    .padding(13)
    .background(
      viewState.isDropTargeted
        ? TransallTheme.accentSoft.opacity(0.44) : TransallTheme.paper.opacity(0.72)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          viewState.isDropTargeted ? TransallTheme.accent : TransallTheme.lineStrong,
          style: StrokeStyle(lineWidth: 1, dash: [5, 5])
        )
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if model.documents.isEmpty, !inputIsLocked {
        viewState.isAppending = false
        viewState.showImporter = true
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !inputIsLocked, !urls.isEmpty else { return false }
      let appending = !model.documents.isEmpty
      Task { await model.importDocuments(urls, appending: appending) }
      return !urls.isEmpty
    } isTargeted: { targeted in
      viewState.isDropTargeted = targeted
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文件选择区")
    .accessibilityHint(
      inputAccessibilityHint
    )
    .accessibilityAddTraits(model.documents.isEmpty && !inputIsLocked ? .isButton : [])
    .accessibilityAction(named: "选择文件") {
      guard !inputIsLocked else { return }
      viewState.isAppending = !model.documents.isEmpty
      viewState.showImporter = true
    }
    .focusable(model.documents.isEmpty && !inputIsLocked)
    .onKeyPress(keys: [.return, .space]) { _ in
      guard model.documents.isEmpty, !inputIsLocked else { return .ignored }
      viewState.isAppending = false
      viewState.showImporter = true
      return .handled
    }
  }

  @ViewBuilder
  private func routeOptions(_ route: RouteDefinition) -> some View {
    if route.optionPanels.contains("translate") {
      translationOptions
    }

    if route.optionPanels.contains("edit") {
      editOptions
    }

    if route.optionPanels.contains("ocr") {
      ocrOptions
    }

    if route.optionPanels.contains("advanced") {
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
      SectionLabel(text: "Translation")
      optionGrid {
        Picker("翻译服务", selection: $model.options.provider) {
          ForEach(model.providers) { provider in
            Text("\(provider.name.capitalized)\(provider.configured ? "" : "（未配置）")")
              .tag(provider.name)
          }
        }
        .controlSize(.small)

        Picker("输出", selection: $model.options.outputMode) {
          Text("纯译文 PDF").tag("translated")
          Text("双语对照 PDF").tag("bilingual")
        }
        .controlSize(.small)
      }

      Label {
        Text(
          "提取文字会发送给所选服务商；任务文件和结果保存在本机。单次最多 \(PDFTranslationPolicy.maximumPages) 页、\(PDFTranslationPolicy.maximumCharacters.formatted()) 个字符，全文检查通过后才开始请求。"
        )
      } icon: {
        Image(systemName: "network")
      }
      .font(.caption2)
      .foregroundStyle(TransallTheme.warning)
      .padding(9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TransallTheme.warning.opacity(0.075))
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
  }

  private var editOptions: some View {
    VStack(alignment: .leading, spacing: 9) {
      SectionLabel(text: "PDF operation")
      Picker("PDF 操作", selection: $model.options.editAction) {
        Text("编辑单个 PDF").tag("edit")
        Text("按列表顺序合并 PDF").tag("merge")
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
    }
  }

  private var ocrOptions: some View {
    VStack(alignment: .leading, spacing: 9) {
      SectionLabel(text: "OCR")
      optionGrid {
        TextField("识别语言，如 zh-Hans,en-US", text: $model.options.ocrLanguage)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        Picker("输出", selection: $model.options.ocrOutputFormat) {
          Text("可搜索 PDF").tag("searchable_pdf")
          Text("纯文本").tag("text")
        }
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func advancedOptions(_ route: RouteDefinition) -> some View {
    if route.optionPanels.contains("translate") {
      VStack(alignment: .leading, spacing: 10) {
        optionGrid {
          TextField("源语言（如 en）", text: $model.options.sourceLanguage)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
          TextField("目标语言（如 zh）", text: $model.options.targetLanguage)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
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
      }
    }
  }

  private func actionBar(_ route: RouteDefinition) -> some View {
    HStack(spacing: 10) {
      Button {
        Task { await model.runJob() }
      } label: {
        if model.isImporting {
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("正在读取文件")
          }
        } else if model.isSubmitting {
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("正在预检")
          }
        } else {
          Text("开始\(route.kindLabel)")
        }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(!model.canRun)

      if model.currentJob?.isRunning == true {
        Button("取消任务") {
          Task { await model.cancelJob() }
        }
        .buttonStyle(QuietButtonStyle())
      }

      Spacer()

      Text("上限 \(model.inputLimitMB) MB")
        .font(.caption2)
        .foregroundStyle(TransallTheme.muted)
    }
  }

  private var unavailableHint: some View {
    Text(model.selection.target == nil ? "在左侧选择源格式和目标格式。" : "这条转换路径尚未接入，请重新选择。")
      .font(.caption)
      .foregroundStyle(TransallTheme.muted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
  }

  private var fileHint: String {
    guard let route = model.route, route.enabled else { return "路径确定后会校验文件类型" }
    return "接受 \(route.accept)"
  }

  private var inputIsLocked: Bool {
    model.isImporting || model.isSubmitting
  }

  private var inputAccessibilityHint: String {
    if model.isImporting { return "全部文件通过校验后才会加入列表" }
    if model.isSubmitting { return "正在创建任务，完成后可修改文件" }
    return model.documents.isEmpty
      ? "按回车键选择文件，也可以将文件拖到这里"
      : "可继续添加或移除文件"
  }

  private var allowedContentTypes: [UTType] {
    guard let source = model.route?.source else { return [.item] }
    switch source {
    case "pdf":
      return [.pdf]
    case "image":
      return [.image]
    case "md":
      return [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    case "html":
      return [.html]
    case "data":
      return [.plainText, .commaSeparatedText, .json]
    default:
      return [.item]
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
