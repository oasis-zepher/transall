import AppKit
import Combine
import SwiftUI

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

  private let worker: ProviderCredentialWorker
  private var storedValues: [ProviderCredential: String] = [:]

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
      messageIsError = false
      message = showSuccess ? "已重新读取钥匙串。" : ""
    } catch {
      clearLoadedValues()
      messageIsError = true
      message = "无法读取钥匙串，现有 API Key 未被更改：\(error.localizedDescription)"
    }
  }

  func save(appModel: AppModel) async {
    guard isLoaded, !isLoading else {
      messageIsError = true
      message = "请先重新读取钥匙串，再保存 API Key。"
      return
    }
    isSaving = true
    defer { isSaving = false }

    let values: [ProviderCredential: String] = [
      .deepseek: deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines),
      .openAI: openAIKey.trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    let previousValues = storedValues
    let changed = ProviderCredential.allCases.filter { values[$0] != previousValues[$0] }
    guard !changed.isEmpty else {
      messageIsError = false
      message = "没有需要保存的更改。"
      return
    }

    do {
      applyLoadedValues(try await worker.save(values, replacing: previousValues))
      messageIsError = false
      message = await appModel.applyCredentialChanges()
    } catch ProviderCredentialTransactionError.save(
      let saveError, _, let actualValues, let reconciliationError, let rollbackErrors)
    {
      messageIsError = true
      if let actualValues {
        applyLoadedValues(actualValues)
        if actualValues == previousValues {
          message = "API Key 保存失败，但已验证钥匙串已恢复到保存前状态：\(saveError)"
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
          message =
            "API Key 保存失败，\(changedProviders) 未恢复到保存前状态；已重新读取钥匙串当前值，请检查后重试：\(saveError)\(rollbackDetail)"
        }
      } else {
        clearLoadedValues()
        let rollbackDetail =
          rollbackErrors.isEmpty
          ? "" : "；回滚错误：\(rollbackErrors.joined(separator: "；"))"
        message =
          "API Key 保存失败，且无法确认钥匙串当前状态：\(saveError)；重新读取失败：\(reconciliationError ?? "未知错误")\(rollbackDetail)"
      }
    } catch {
      clearLoadedValues()
      messageIsError = true
      message = "API Key 保存失败，且无法确认钥匙串当前状态：\(error.localizedDescription)"
    }
  }

  func remove(
    _ credential: ProviderCredential, appModel: AppModel
  ) async {
    guard isLoaded, !isLoading else {
      messageIsError = true
      message = "请先重新读取钥匙串，再删除 API Key。"
      return
    }
    isSaving = true
    defer { isSaving = false }
    pendingRemoval = nil
    do {
      applyLoadedValues(try await worker.remove(credential, from: storedValues))
      _ = await appModel.applyCredentialChanges()
      messageIsError = false
      message = "\(credential.displayName) API Key 已从钥匙串删除。"
    } catch ProviderCredentialTransactionError.removal(
      _, let removalError, let actualValues, let reconciliationError)
    {
      messageIsError = true
      if let actualValues {
        applyLoadedValues(actualValues)
        _ = await appModel.applyCredentialChanges()
        if actualValues[credential]?.isEmpty != false {
          message =
            "\(credential.displayName) API Key 实际已删除，但钥匙串清理返回错误；已重新读取当前状态：\(removalError)"
        } else {
          message =
            "\(credential.displayName) API Key 删除失败；已重新读取钥匙串当前状态：\(removalError)"
        }
      } else {
        clearLoadedValues()
        message =
          "\(credential.displayName) API Key 删除失败，且无法确认钥匙串当前状态：\(removalError)；重新读取失败：\(reconciliationError ?? "未知错误")"
      }
    } catch {
      clearLoadedValues()
      messageIsError = true
      message =
        "\(credential.displayName) API Key 删除失败，且无法确认钥匙串当前状态：\(error.localizedDescription)"
    }
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
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @StateObject private var settings = ProviderSettingsModel()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 4) {
          Text("翻译与隐私")
            .font(.system(.title2, design: .serif, weight: .semibold))
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
          Text("本地任务数据")
            .font(.callout.weight(.semibold))
          Label("文件副本、结果、预览和日志保存在 Transall 的 App 容器内。", systemImage: "internaldrive")
          Label(
            "任务数据超过 24 小时后，会在启动时及运行期间定期自动清理；也可以在结果区立即删除。",
            systemImage: "clock.arrow.circlepath")
          Label("处理过程不会删除或修改原始文件；保存结果时由你选择目标位置。", systemImage: "checkmark.shield")
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
          .disabled(settings.isSaving || settings.isLoading || !settings.isLoaded)
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
    .onChange(of: settings.message) { _, message in
      guard !message.isEmpty else { return }
      NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
          .announcement: message,
          .priority: settings.messageIsError
            ? NSAccessibilityPriorityLevel.high.rawValue
            : NSAccessibilityPriorityLevel.medium.rawValue,
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
    let configured =
      settings.isLoaded
      && !key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let status =
      settings.isLoading ? "正在读取" : (settings.isLoaded ? (configured ? "已配置" : "未配置") : "读取失败")
    let statusIcon =
      settings.isLoading
      ? "clock"
      : (settings.isLoaded
        ? (configured ? "checkmark.circle.fill" : "circle")
        : "exclamationmark.triangle.fill")
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(credential.displayName)
          .font(.callout.weight(.semibold))
        Spacer()
        Label(status, systemImage: statusIcon)
          .font(.caption)
          .foregroundStyle(
            settings.isLoading
              ? TransallTheme.muted
              : settings.isLoaded
              ? (configured ? TransallTheme.source : TransallTheme.muted) : TransallTheme.danger)
      }

      HStack {
        SecureField("\(credential.displayName) API Key", text: key)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("\(credential.displayName) API Key")
          .disabled(!settings.isLoaded || settings.isSaving || settings.isLoading)

        Button("删除密钥", role: .destructive) {
          settings.pendingRemoval = credential
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!configured || settings.isSaving || settings.isLoading || !settings.isLoaded)
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
}
