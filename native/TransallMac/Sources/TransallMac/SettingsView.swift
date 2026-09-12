import AppKit
import Combine
import SwiftUI

enum SettingsAnnouncementPriority: Equatable {
  case medium
  case high
}

struct SettingsAnnouncement: Equatable, Identifiable {
  let id: UUID
  let message: String
  let priority: SettingsAnnouncementPriority
}

enum ProviderCredentialStorageState: Equatable {
  case unavailable
  case notConfigured
  case configured
  case invalid
}

enum ProviderCredentialStatusStyle: Equatable {
  case muted
  case configured
  case pending
  case invalid
}

struct ProviderCredentialRowState: Equatable {
  let storage: ProviderCredentialStorageState
  let hasStoredValue: Bool
  let hasUnsavedChanges: Bool
  let draftValidationError: ProviderCredentialValidationError?

  var statusLabel: String {
    let storedLabel =
      switch storage {
      case .unavailable: "读取失败"
      case .notConfigured: "未配置"
      case .configured: "已配置"
      case .invalid: "密钥无效"
      }
    if hasUnsavedChanges, draftValidationError != nil {
      return "\(storedLabel) · 输入无效，未保存"
    }
    return hasUnsavedChanges ? "\(storedLabel) · 待保存" : storedLabel
  }

  var statusIcon: String {
    if hasUnsavedChanges, draftValidationError != nil {
      return "exclamationmark.triangle.fill"
    }
    if hasUnsavedChanges { return "pencil.circle.fill" }
    return switch storage {
    case .unavailable, .invalid: "exclamationmark.triangle.fill"
    case .notConfigured: "circle"
    case .configured: "checkmark.circle.fill"
    }
  }

  var statusStyle: ProviderCredentialStatusStyle {
    if hasUnsavedChanges, draftValidationError != nil { return .invalid }
    if hasUnsavedChanges { return .pending }
    return switch storage {
    case .unavailable, .invalid: .invalid
    case .notConfigured: .muted
    case .configured: .configured
    }
  }

  var canRemoveStoredValue: Bool { hasStoredValue }
}

@MainActor
final class ProviderSettingsModel: ObservableObject {
  @Published var deepseekKey = ""
  @Published var openAIKey = ""
  @Published var message = ""
  @Published var isSaving = false
  @Published var pendingRemoval: ProviderCredential?
  @Published private(set) var isLoading = false
  @Published private(set) var isLoaded = false
  @Published private(set) var messageIsError = false
  @Published private(set) var announcement: SettingsAnnouncement?

  private let worker: ProviderCredentialWorker
  private var storedValues: [ProviderCredential: String] = [:]

  var hasUnsavedChanges: Bool {
    guard isLoaded else { return false }
    return ProviderCredential.allCases.contains { credential in
      draftValue(for: credential) != (storedValues[credential] ?? "")
    }
  }

  init(
    store: (any ProviderCredentialStoring)? = nil,
    worker: ProviderCredentialWorker? = nil
  ) {
    if let worker {
      self.worker = worker
    } else if let store {
      self.worker = ProviderCredentialWorker(store: store)
    } else {
      self.worker = .shared
    }
  }

  func reload(showSuccess: Bool = true) async {
    guard !isSaving, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      applyLoadedValues(try await worker.readStoredValues())
      publish(showSuccess ? "已重新读取钥匙串。" : "", isError: false)
    } catch {
      clearLoadedValues()
      publish(
        "无法读取钥匙串，现有 API Key 未被更改：\(error.localizedDescription)",
        isError: true)
    }
  }

  func save(appModel: AppModel) async {
    guard !isSaving else { return }
    guard isLoaded, !isLoading else {
      publish("请先重新读取钥匙串，再保存 API Key。", isError: true)
      return
    }

    let editedValues: [ProviderCredential: String] = [
      .deepseek: deepseekKey,
      .openAI: openAIKey,
    ]
    var values: [ProviderCredential: String] = [:]
    for credential in ProviderCredential.allCases {
      do {
        values[credential] = try ProviderCredentialPolicy.normalizedValue(
          editedValues[credential] ?? "", allowingEmpty: true)
      } catch {
        publish(
          "\(credential.displayName) API Key 格式无效：\(error.localizedDescription)",
          isError: true)
        return
      }
    }

    let previousValues = storedValues
    let changed = ProviderCredential.allCases.filter { values[$0] != previousValues[$0] }
    guard !changed.isEmpty else {
      applyLoadedValues(previousValues)
      publish("没有需要保存的更改。", isError: false)
      return
    }

    isSaving = true
    defer { isSaving = false }
    do {
      applyLoadedValues(try await worker.save(values, replacing: previousValues))
      publish(await appModel.applyCredentialChanges(), isError: false)
    } catch ProviderCredentialTransactionError.save(
      let saveError, _, let actualValues, let reconciliationError, let rollbackErrors)
    {
      if let actualValues {
        applyLoadedValues(actualValues)
        if actualValues == previousValues {
          publish(
            "API Key 保存失败，但已验证钥匙串已恢复到保存前状态：\(saveError)",
            isError: true)
        } else {
          _ = await appModel.applyCredentialChanges()
          let changedProviders =
            ProviderCredential.allCases
            .filter { actualValues[$0] != previousValues[$0] }
            .map(\.displayName)
            .joined(separator: "、")
          let rollbackDetail =
            rollbackErrors.isEmpty
            ? "" : "；回滚错误：\(rollbackErrors.joined(separator: "；"))"
          publish(
            "API Key 保存失败，\(changedProviders) 未恢复到保存前状态；已重新读取钥匙串当前值，请检查后重试：\(saveError)\(rollbackDetail)",
            isError: true)
        }
      } else {
        clearLoadedValues()
        let rollbackDetail =
          rollbackErrors.isEmpty
          ? "" : "；回滚错误：\(rollbackErrors.joined(separator: "；"))"
        publish(
          "API Key 保存失败，且无法确认钥匙串当前状态：\(saveError)；重新读取失败：\(reconciliationError ?? "未知错误")\(rollbackDetail)",
          isError: true)
      }
    } catch {
      clearLoadedValues()
      publish(
        "API Key 保存失败，且无法确认钥匙串当前状态：\(error.localizedDescription)",
        isError: true)
    }
  }

  func remove(
    _ credential: ProviderCredential, appModel: AppModel
  ) async {
    guard !isSaving else { return }
    guard isLoaded, !isLoading else {
      publish("请先重新读取钥匙串，再删除 API Key。", isError: true)
      return
    }
    isSaving = true
    defer { isSaving = false }
    pendingRemoval = nil
    do {
      applyLoadedValues(try await worker.remove(credential, from: storedValues))
      _ = await appModel.applyCredentialChanges()
      publish("\(credential.displayName) API Key 已从钥匙串删除。", isError: false)
    } catch ProviderCredentialTransactionError.removal(
      _, let removalError, let actualValues, let reconciliationError)
    {
      if let actualValues {
        applyLoadedValues(actualValues)
        _ = await appModel.applyCredentialChanges()
        if actualValues[credential]?.isEmpty != false {
          publish(
            "\(credential.displayName) API Key 实际已删除，但钥匙串清理返回错误；已重新读取当前状态：\(removalError)",
            isError: true)
        } else {
          publish(
            "\(credential.displayName) API Key 删除失败；已重新读取钥匙串当前状态：\(removalError)",
            isError: true)
        }
      } else {
        clearLoadedValues()
        publish(
          "\(credential.displayName) API Key 删除失败，且无法确认钥匙串当前状态：\(removalError)；重新读取失败：\(reconciliationError ?? "未知错误")",
          isError: true)
      }
    } catch {
      clearLoadedValues()
      publish(
        "\(credential.displayName) API Key 删除失败，且无法确认钥匙串当前状态：\(error.localizedDescription)",
        isError: true)
    }
  }

  private func publish(_ message: String, isError: Bool) {
    messageIsError = isError
    self.message = message
    announcement =
      message.isEmpty
      ? nil
      : SettingsAnnouncement(
        id: UUID(), message: message, priority: isError ? .high : .medium)
  }

  func rowState(for credential: ProviderCredential) -> ProviderCredentialRowState {
    guard isLoaded else {
      return ProviderCredentialRowState(
        storage: .unavailable, hasStoredValue: false, hasUnsavedChanges: false,
        draftValidationError: nil)
    }

    let storedValue = storedValues[credential] ?? ""
    let draftValue = draftValue(for: credential)
    let storage: ProviderCredentialStorageState
    do {
      let normalized = try ProviderCredentialPolicy.normalizedValue(
        storedValue, allowingEmpty: true)
      storage = normalized.isEmpty ? .notConfigured : .configured
    } catch {
      storage = .invalid
    }
    let draftValidationError: ProviderCredentialValidationError?
    do {
      _ = try ProviderCredentialPolicy.normalizedValue(draftValue, allowingEmpty: true)
      draftValidationError = nil
    } catch let error as ProviderCredentialValidationError {
      draftValidationError = error
    } catch {
      draftValidationError = .invalidCharacters
    }
    return ProviderCredentialRowState(
      storage: storage, hasStoredValue: !storedValue.isEmpty,
      hasUnsavedChanges: draftValue != storedValue,
      draftValidationError: draftValidationError)
  }

  private func applyLoadedValues(_ values: [ProviderCredential: String]) {
    deepseekKey = values[.deepseek] ?? ""
    openAIKey = values[.openAI] ?? ""
    storedValues = values
    isLoaded = true
  }

  private func clearLoadedValues() {
    deepseekKey = ""
    openAIKey = ""
    storedValues = [:]
    isLoaded = false
  }

  private func draftValue(for credential: ProviderCredential) -> String {
    switch credential {
    case .deepseek: deepseekKey
    case .openAI: openAIKey
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @StateObject private var settings = ProviderSettingsModel()
  @State private var conversionMessage = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 4) {
          Text("翻译与隐私")
            .font(.title2.weight(.semibold))
          Text("API Key 只保存在 macOS 钥匙串，不写入任务文件或日志。")
            .font(.caption)
            .foregroundStyle(TransallTheme.muted)
        }

        providerRow(
          credential: .deepseek, key: $settings.deepseekKey,
          privacyURL: "https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html")

        Divider().overlay(TransallTheme.line)

        providerRow(
          credential: .openAI, key: $settings.openAIKey,
          privacyURL: "https://openai.com/policies/privacy-policy/")

        Label {
          Text("只有主动执行翻译时，提取出的文档文字才会发送给所选服务商。PDF 原文件不会上传。")
        } icon: {
          Image(systemName: "network")
        }
        .font(.caption)
        .foregroundStyle(TransallTheme.warning)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TransallTheme.warning.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 5))

        VStack(alignment: .leading, spacing: 8) {
          LabeledContent(
            "Office 文档转换",
            value: OfficeDocumentConverter.executable == nil
              ? "未安装 LibreOffice" : (OfficeConversionComponent.requiresSetup ? "待启用" : "可用"))
          if OfficeConversionComponent.requiresSetup {
            Button("启用 Office 转换…") { conversionMessage = OfficeConversionComponent.install() }
          }
          if !conversionMessage.isEmpty { Text(conversionMessage).textSelection(.enabled) }
          if OfficeDocumentConverter.executable == nil {
            Link(
              "获取 LibreOffice",
              destination: URL(
                string: "https://www.libreoffice.org/download/download-libreoffice/")!)
          }
          Text("Transall 数据与隐私")
            .font(.callout.weight(.semibold))
          Label("文件副本、结果、预览和日志保存在 Transall 的 App 容器内。", systemImage: "internaldrive")
          Label(
            "任务数据超过 24 小时后，会在启动时及运行期间定期自动清理；也可以在结果区立即删除。",
            systemImage: "clock.arrow.circlepath")
          Label("处理过程不会删除或修改原始文件；保存结果时由你选择目标位置。", systemImage: "checkmark.shield")
          if let privacyPolicyURL = PrivacyPolicyConfiguration.appURL {
            Link(destination: privacyPolicyURL) {
              Label("查看 Transall 隐私政策", systemImage: "hand.raised")
            }
            .foregroundStyle(TransallTheme.accent)
            .accessibilityHint("在浏览器中打开 Transall 的公开隐私政策")
          } else {
            Label("发布版隐私政策网址尚未配置", systemImage: "exclamationmark.triangle")
              .foregroundStyle(TransallTheme.warning)
              .accessibilityHint("归档发布版前必须配置公开 HTTPS 地址")
          }
        }
        .font(.caption)
        .foregroundStyle(TransallTheme.inkSoft)

        if !settings.message.isEmpty {
          Text(settings.message)
            .font(.caption)
            .foregroundStyle(settings.messageIsError ? TransallTheme.danger : TransallTheme.inkSoft)
            .textSelection(.enabled)
        }

        HStack {
          if !settings.isLoaded {
            Button("重新读取钥匙串") {
              Task { await settings.reload() }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(settings.isSaving || settings.isLoading)
          }
          Spacer()
          Button(settings.isSaving ? "正在保存" : "保存并应用") {
            Task { await settings.save(appModel: appModel) }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(
            settings.isSaving || settings.isLoading || !settings.isLoaded
              || !settings.hasUnsavedChanges)
        }
      }
      .padding(24)
    }
    .frame(width: 540)
    .frame(minHeight: 560)
    .background(TransallTheme.paper)
    .task {
      if !settings.isLoaded {
        await settings.reload(showSuccess: false)
      }
    }
    .onChange(of: settings.announcement) { _, announcement in
      guard let announcement else { return }
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement.message,
          .priority: accessibilityPriority(for: announcement.priority).rawValue,
        ])
    }
    .confirmationDialog(
      removalTitle,
      isPresented: Binding(
        get: { settings.pendingRemoval != nil },
        set: { if !$0 { settings.pendingRemoval = nil } }
      )
    ) {
      if let credential = settings.pendingRemoval {
        Button("从钥匙串删除", role: .destructive) {
          Task { await settings.remove(credential, appModel: appModel) }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，对应翻译服务将不可用；稍后可以重新填写。")
    }
  }

  private func providerRow(
    credential: ProviderCredential, key: Binding<String>, privacyURL: String
  ) -> some View {
    let state = settings.rowState(for: credential)
    let status = settings.isLoading ? "正在读取" : state.statusLabel
    let statusIcon = settings.isLoading ? "clock" : state.statusIcon
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(credential.displayName)
          .font(.callout.weight(.semibold))
        Spacer()
        Label(status, systemImage: statusIcon)
          .font(.caption)
          .foregroundStyle(
            settings.isLoading ? TransallTheme.muted : statusColor(state.statusStyle))
      }

      HStack {
        SecureField("\(credential.displayName) API Key", text: key)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("\(credential.displayName) API Key")
          .accessibilityValue(status)
          .disabled(!settings.isLoaded || settings.isSaving || settings.isLoading)

        Button("删除密钥", role: .destructive) {
          settings.pendingRemoval = credential
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(
          !state.canRemoveStoredValue || settings.isSaving || settings.isLoading
            || !settings.isLoaded)
      }

      if let url = URL(string: privacyURL) {
        Link("查看 \(credential.displayName) 隐私政策", destination: url)
          .font(.caption)
      }
    }
  }

  private var removalTitle: String {
    guard let credential = settings.pendingRemoval else { return "删除 API Key？" }
    return "删除 \(credential.displayName) API Key？"
  }

  private func statusColor(_ style: ProviderCredentialStatusStyle) -> Color {
    switch style {
    case .muted: TransallTheme.muted
    case .configured: TransallTheme.source
    case .pending: TransallTheme.warning
    case .invalid: TransallTheme.danger
    }
  }

  private func accessibilityPriority(
    for priority: SettingsAnnouncementPriority
  ) -> NSAccessibilityPriorityLevel {
    switch priority {
    case .medium: .medium
    case .high: .high
    }
  }
}
