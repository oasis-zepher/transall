import AppKit
import SwiftUI

private final class ResultViewState: ObservableObject {
  @Published var pendingDeletionJobID: String?
}

enum JobStatusAnnouncementPriority: Equatable {
  case medium
  case high
}

struct JobStatusAnnouncement: Equatable {
  let message: String
  let priority: JobStatusAnnouncementPriority
}

enum JobStatusAnnouncementPolicy {
  static let maximumAnnouncementCharacters = 500

  static func announcement(for job: JobResponse?) -> JobStatusAnnouncement? {
    guard let job else { return nil }
    switch job.status {
    case "done":
      return JobStatusAnnouncement(
        message: "任务已完成，结果可以保存。", priority: .medium)
    case "failed":
      let details = [job.error, job.errorHint]
        .compactMap { value -> String? in
          guard let value else { return nil }
          let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
      let message = (["任务失败。"] + details).joined(separator: " ")
      return JobStatusAnnouncement(message: bounded(message), priority: .high)
    case "cancelled":
      return JobStatusAnnouncement(message: "任务已取消。", priority: .medium)
    default:
      return nil
    }
  }

  private static func bounded(_ message: String) -> String {
    guard message.count > maximumAnnouncementCharacters else { return message }
    return String(message.prefix(maximumAnnouncementCharacters - 1)) + "…"
  }
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

        previewFailure

        if !model.previewPages.isEmpty {
          Divider().overlay(TransallTheme.line)
          PreviewGridView(pages: model.previewPages)
        }
      }
    }
    .confirmationDialog(
      "删除这个任务的本地文件？",
      isPresented: Binding(
        get: { viewState.pendingDeletionJobID != nil },
        set: { if !$0 { viewState.pendingDeletionJobID = nil } }
      )
    ) {
      if let jobID = viewState.pendingDeletionJobID {
        Button("删除任务数据", role: .destructive) {
          Task { await model.deleteCurrentJob(id: jobID) }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("上传副本、结果和预览会从本机删除；原始文件不受影响。")
    }
    .onChange(of: model.previewError) { _, error in
      guard let error else { return }
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: error,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
    .onChange(of: model.currentJob?.status) { _, _ in
      guard let announcement = JobStatusAnnouncementPolicy.announcement(for: model.currentJob)
      else { return }
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement.message,
          .priority: accessibilityPriority(for: announcement.priority).rawValue,
        ])
    }
    .onChange(of: model.currentJob?.id) { _, jobID in
      guard let pendingJobID = viewState.pendingDeletionJobID, pendingJobID != jobID else {
        return
      }
      viewState.pendingDeletionJobID = nil
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
          .accessibilityHidden(true)
        Text(output)
          .font(.caption2.weight(.medium))
          .lineLimit(3)
          .truncationMode(.middle)
          .help(output)
        if model.requiresNewResultDestination {
          Label("恢复的任务只能另存为新文件", systemImage: "lock.doc")
            .font(.caption2)
            .foregroundStyle(TransallTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.isSaving {
          ProgressView("正在保存")
            .controlSize(.small)
            .font(.caption2)
            .foregroundStyle(TransallTheme.muted)
          Button("取消保存", role: .cancel) {
            Task { await model.cancelResultSaving() }
          }
          .buttonStyle(QuietButtonStyle())
          .help("停止当前结果复制；已有目标文件保持不变")
        } else {
          Button("保存结果…") {
            model.startSavingResult()
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!model.canStartSavingResult)
        }

        if model.hasPreviewableResult {
          Button(previewButtonLabel) {
            Task { await model.refreshPreview() }
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(model.isLoadingPreview || model.isDeletingJob)
        }

      } else {
        Text(artifactStatusMessage)
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let job = model.currentJob, !job.isRunning {
        Button(model.isDeletingJob ? "正在删除" : "删除任务数据", role: .destructive) {
          viewState.pendingDeletionJobID = job.id
        }
        .font(.caption2.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(TransallTheme.danger)
        .disabled(!model.canDeleteCurrentJob)
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

  @ViewBuilder
  private var previewFailure: some View {
    if let error = model.previewError {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundStyle(TransallTheme.warning)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TransallTheme.warning.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(error)
    }
  }

  private var previewButtonLabel: String {
    if model.isLoadingPreview { return "正在生成预览" }
    return model.previewPages.isEmpty ? "生成预览" : "刷新预览"
  }

  private var artifactStatusMessage: String {
    switch model.currentJob?.status {
    case "failed": "任务失败，详情见运行日志。"
    case "cancelled": "任务已取消，没有可保存的结果。"
    default: "完成后可另存结果；处理过程不会修改原文件。"
    }
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

  private func accessibilityPriority(
    for priority: JobStatusAnnouncementPriority
  ) -> NSAccessibilityPriorityLevel {
    switch priority {
    case .medium: .medium
    case .high: .high
    }
  }
}
