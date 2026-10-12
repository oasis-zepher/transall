import AppKit
import SwiftUI

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

// Classifies task state so the fixed execution slot can present cancellation while busy.
enum TaskToolbarAction: Equatable {
  case addFiles, start, retry, save, cancelImport, cancelSubmission, cancelSaving, cancelJob,
    deleting

  @MainActor
  init(model: AppModel) {
    if model.isDeletingJob {
      self = .deleting
    } else if model.isImporting {
      self = .cancelImport
    } else if model.isSubmitting {
      self = .cancelSubmission
    } else if model.isSaving {
      self = .cancelSaving
    } else if model.currentJob?.isRunning == true {
      self = .cancelJob
    } else if model.currentJob?.status == "done" {
      self = .save
    } else if model.documents.isEmpty {
      self = .addFiles
    } else if model.currentJob?.isFinished == true {
      self = .retry
    } else {
      self = .start
    }
  }
}

struct TaskExecutionButton: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      switch TaskToolbarAction(model: model) {
      case .cancelImport:
        Button("取消读取", systemImage: "xmark") { model.requestDocumentImportCancellation() }
      case .cancelSubmission:
        Button("取消执行", systemImage: "xmark") { model.requestJobSubmissionCancellation() }
      case .cancelSaving:
        Button("取消保存", systemImage: "xmark") { Task { await model.cancelResultSaving() } }
      case .cancelJob:
        Button("取消执行", systemImage: "xmark") { Task { await model.cancelJob() } }
      case .deleting:
        Button("正在删除…", systemImage: "hourglass") {}.disabled(true)
      default:
        Button("开始执行", systemImage: "play.fill") { model.startJob() }
          .disabled(!model.canRun)
          .keyboardShortcut(.return, modifiers: .command)
          .help(model.currentJob?.isFinished == true ? "使用当前参数重新执行（⌘↩）" : "开始执行（⌘↩）")
      }
    }
    .controlSize(.regular).labelStyle(.iconOnly)
    .accessibilityIdentifier("task.primaryAction")
  }
}

struct ResultWorkbenchView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showDetails = false
  @State private var pendingDeletionJobID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if case .failed(let message) = model.backend.state {
        HStack {
          Label(message, systemImage: "exclamationmark.triangle").font(.callout)
          Button("重试") { Task { await model.retryBackend() } }
        }.padding(12)
      }
      ForEach(model.preflightWarnings) { warning in
        Label(
          [warning.message, warning.hint].compactMap { $0 }.joined(separator: " "),
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption).foregroundStyle(TransallTheme.warning).padding(12)
      }
      if let job = model.currentJob, job.status == "failed", model.translationRecoveryError == nil {
        VStack(alignment: .leading, spacing: 4) {
          Label(job.error ?? "任务未完成", systemImage: "exclamationmark.triangle")
            .foregroundStyle(TransallTheme.danger)
          if let hint = job.errorHint { Text(hint).foregroundStyle(.secondary) }
        }
        .font(.callout).textSelection(.enabled).padding(12)
      }
      if let recovery = model.translationRecovery, recovery.jobID == model.currentJob?.id,
        !recovery.isComplete
      {
        VStack(alignment: .leading, spacing: 8) {
          Text("已保存 \(recovery.completedRegionCount ?? 0)/\(recovery.regionCount) 个区域的译文")
            .font(.callout.weight(.medium))
          Button("继续翻译") { model.startJob() }.disabled(!model.canRun)
          Text("重新执行仅补译未完成区域。重新打开 App 后，先添加同一份原文件。")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
      } else if let recovery = model.translationRecovery, recovery.jobID == model.currentJob?.id {
        VStack(alignment: .leading, spacing: 8) {
          Text("译文已保存，可以继续生成 PDF").font(.callout.weight(.medium))
          Text(recovery.issueCount > 0 ? "\(recovery.issueCount) 处译文放不进原文区域。" : "可以使用已完成的译文重新排版。")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("生成左右对照 PDF") { model.rebuildTranslationPDF(outputMode: "bilingual") }
              .buttonStyle(.bordered).disabled(!model.canRecoverTranslation)
            Button("生成纯译文 PDF") { model.recoverTranslationAsPlainPDF(jobID: recovery.jobID) }
              .buttonStyle(.bordered).disabled(!model.canRecoverTranslation)
            if let page = recovery.issuePages.first {
              Button("查看问题区域") { model.inspectionPage = page }
                .disabled(model.isDeletingJob || model.isSubmitting)
            }
          }
          Text("使用本机已有译文，不会再次请求翻译服务；页数和版式可能改变。")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
      } else if let error = model.translationRecoveryError {
        Text(error).font(.caption).foregroundStyle(TransallTheme.warning).padding(12)
      }
      HStack(spacing: 10) {
        if busy {
          TaskProgressView(
            engine: model.backend,
            jobID: model.isImporting || model.isSubmitting || model.isSaving || model.isDeletingJob
              ? nil : model.currentJob?.id,
            fallbackTitle: statusText
          )
          .frame(maxWidth: .infinity)
        } else {
          Text(statusText).font(.callout).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
        }
        if let job = model.currentJob, job.isFinished {
          Menu {
            if job.kind == "pdf_translate", job.status == "done" {
              Button("用已保存译文生成左右对照 PDF") { model.rebuildTranslationPDF(outputMode: "bilingual") }
                .disabled(model.isSubmitting || model.isSaving || model.isDeletingJob)
            }
            Button("新任务") {
              let task = model.selectedTask
              let source = model.selection.source
              model.resetRoute(animated: false)
              model.selectTask(task, source: source)
            }
            .disabled(!model.canChangeRoute)
            if job.status == "done", !model.documents.isEmpty {
              Button("重新处理") { model.startJob() }.disabled(!model.canRun)
            }
            Button("删除任务数据", role: .destructive) { pendingDeletionJobID = job.id }
              .disabled(!model.canDeleteCurrentJob)
          } label: {
            Label("任务操作", systemImage: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton).fixedSize().labelStyle(.iconOnly)
        }
        Button {
          showDetails.toggle()
        } label: {
          Label("处理详情", systemImage: showDetails ? "chevron.down" : "chevron.up")
        }.buttonStyle(.borderless).font(.caption)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      if model.requiresNewResultDestination {
        Text("恢复的任务只能另存为新文件").font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.bottom, 10)
      }
      if showDetails {
        Divider()
        ScrollView {
          Text(model.logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
        }.frame(height: 140).background(TransallTheme.panel)
      }
    }
    .background(TransallTheme.paper)
    .confirmationDialog(
      "删除这个任务的本地文件？",
      isPresented: Binding(
        get: { pendingDeletionJobID != nil }, set: { if !$0 { pendingDeletionJobID = nil } }
      )
    ) {
      if let jobID = pendingDeletionJobID {
        Button("删除任务数据", role: .destructive) { Task { await model.deleteCurrentJob(id: jobID) } }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("文件副本、结果和预览会从本机删除；原始文件不受影响。")
    }
    .onChange(of: model.currentJob?.id) { _, jobID in
      if pendingDeletionJobID != jobID { pendingDeletionJobID = nil }
    }
    .onChange(of: model.currentJob?.status) { _, _ in
      guard let announcement = JobStatusAnnouncementPolicy.announcement(for: model.currentJob)
      else { return }
      NSAccessibility.post(
        element: NSApplication.shared, notification: .announcementRequested,
        userInfo: [
          .announcement: announcement.message,
          .priority: announcement.priority == .high
            ? NSAccessibilityPriorityLevel.high.rawValue
            : NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }

  private var busy: Bool {
    model.isImporting || model.isSubmitting || model.isSaving || model.isDeletingJob
      || model.currentJob?.isRunning == true
  }

  private var statusText: String {
    if model.isImporting { return "正在读取文件" }
    if model.isSubmitting { return "正在准备任务" }
    if model.isSaving { return "正在保存结果" }
    if model.isDeletingJob { return "正在删除任务" }
    guard let job = model.currentJob else {
      return model.documents.isEmpty ? "添加文件以开始" : "已添加 \(model.documents.count) 个文件"
    }
    switch job.status {
    case "done": return "已完成 · \(job.output ?? "结果可以保存")"
    case "failed": return "处理失败"
    case "cancelled": return "已取消"
    default: return "正在处理文档"
    }
  }
}

struct TaskProgressView: View {
  @ObservedObject var engine: NativeDocumentEngine
  let jobID: String?
  let fallbackTitle: String

  private var lines: [TaskProgressLine] {
    if let jobID, let lines = engine.taskProgress[jobID], !lines.isEmpty {
      return lines.sorted {
        if $0.id == "translation-total" { return $1.id != "translation-total" }
        if $1.id == "translation-total" { return false }
        return $0.id < $1.id
      }
    }
    return [TaskProgressLine(title: fallbackTitle)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(lines) { line in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(line.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let fraction = line.fraction {
              Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
          }
          .font(.caption)
          .fontWeight(line.id == "translation-total" ? .semibold : .regular)
          .foregroundStyle(line.id == "translation-total" ? .primary : .secondary)
          ProgressView(value: line.fraction, total: 1)
            .progressViewStyle(.linear).controlSize(.small)
            .tint(TransallTheme.accent)
            .accessibilityLabel(line.title)
            .accessibilityValue(
              line.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "正在进行")
          if line.id == "translation-total" {
            Text("百分比按已完成文字量计算；下方页码表示各任务当前处理页")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }
    .accessibilityIdentifier("task.progress")
  }
}
