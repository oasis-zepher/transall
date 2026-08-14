import SwiftUI

private final class ResultViewState: ObservableObject {
  @Published var showDeleteConfirmation = false
}

struct ResultWorkbenchView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var viewState = ResultViewState()

  var body: some View {
    WorkbenchPanel {
      VStack(alignment: .leading, spacing: 14) {
        header

        if let job = model.currentJob {
          if job.isRunning {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("任务正在处理")
              .accessibilityValue(statusLabel(job.status))
          } else if job.status == "done" {
            ProgressView(value: 1, total: 1)
              .tint(TransallTheme.source)
              .accessibilityLabel("任务进度")
              .accessibilityValue("已完成")
          }
        }

        warnings

        HStack(alignment: .top, spacing: 12) {
          logPane
          artifactPane
            .frame(width: 188)
        }

        if !model.previewPages.isEmpty {
          Divider().overlay(TransallTheme.line)
          PreviewGridView(pages: model.previewPages)
        }
      }
    }
    .confirmationDialog(
      "删除这个任务的本地文件？",
      isPresented: $viewState.showDeleteConfirmation
    ) {
      Button("删除任务数据", role: .destructive) {
        Task { await model.deleteCurrentJob() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("上传副本、结果和预览会从本机删除；原始文件不受影响。")
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        SectionLabel(text: "Output")
        Text("任务输出")
          .font(.system(.title3, design: .serif, weight: .semibold))
      }
      Spacer()
      if let job = model.currentJob {
        HStack(spacing: 6) {
          Circle()
            .fill(statusColor(job.status))
            .frame(width: 6, height: 6)
          Text(statusLabel(job.status))
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(statusColor(job.status))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(statusColor(job.status).opacity(0.08))
        .clipShape(Capsule())
      } else {
        Text("未开始")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(TransallTheme.muted)
      }
    }
  }

  @ViewBuilder
  private var warnings: some View {
    if !model.preflightWarnings.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(model.preflightWarnings) { warning in
          Label(
            [warning.message, warning.hint].compactMap { $0 }.joined(separator: " "),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption2)
          .foregroundStyle(TransallTheme.warning)
        }
      }
      .padding(9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TransallTheme.warning.opacity(0.07))
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
  }

  private var logPane: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("运行日志")
        .font(.caption.weight(.semibold))
      ScrollView {
        Text(model.logText)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(TransallTheme.inkSoft)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(10)
      }
      .frame(minHeight: 112, maxHeight: 190)
      .background(TransallTheme.paper.opacity(0.78))
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(TransallTheme.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var artifactPane: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("结果文件")
        .font(.caption.weight(.semibold))

      if let job = model.currentJob, job.status == "done", let output = job.output {
        Image(systemName: "doc.circle.fill")
          .font(.title2)
          .foregroundStyle(TransallTheme.source)
        Text(output)
          .font(.caption2.weight(.medium))
          .lineLimit(3)
        Button(model.isSaving ? "正在保存" : "保存结果…") {
          Task { await model.saveResult() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.isSaving)

        if !model.previewPages.isEmpty {
          Button("刷新预览") {
            Task { await model.refreshPreview() }
          }
          .buttonStyle(QuietButtonStyle())
        }

        Button("删除任务数据", role: .destructive) {
          viewState.showDeleteConfirmation = true
        }
        .font(.caption2.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(TransallTheme.danger)
      } else {
        Text("完成后可在这里保存，不会覆盖原文件。")
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
    .background(TransallTheme.panelMuted.opacity(0.58))
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(TransallTheme.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private func statusLabel(_ status: String) -> String {
    switch status {
    case "queued": "排队中"
    case "running": "处理中"
    case "done": "已完成"
    case "failed": "失败"
    case "cancelled": "已取消"
    default: status
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "done": TransallTheme.source
    case "failed": TransallTheme.danger
    case "cancelled": TransallTheme.muted
    case "queued", "running": TransallTheme.accent
    default: TransallTheme.lineStrong
    }
  }
}
