import Combine
import SwiftUI

@MainActor
private final class ProviderSettingsModel: ObservableObject {
  @Published var deepseekKey: String
  @Published var openAIKey: String
  @Published var message = ""
  @Published var isSaving = false
  @Published var pendingRemoval: ProviderCredential?

  init(store: ProviderCredentialStore = .shared) {
    deepseekKey = (try? store.value(for: .deepseek)) ?? ""
    openAIKey = (try? store.value(for: .openAI)) ?? ""
  }

  func save(appModel: AppModel, store: ProviderCredentialStore = .shared) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try store.setValue(deepseekKey, for: .deepseek)
      try store.setValue(openAIKey, for: .openAI)
      message = await appModel.applyCredentialChanges()
    } catch {
      message = error.localizedDescription
    }
  }

  func remove(
    _ credential: ProviderCredential, appModel: AppModel,
    store: ProviderCredentialStore = .shared
  ) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try store.setValue("", for: credential)
      switch credential {
      case .deepseek: deepseekKey = ""
      case .openAI: openAIKey = ""
      }
      pendingRemoval = nil
      _ = await appModel.applyCredentialChanges()
      message = "\(credential.displayName) API Key 已从钥匙串删除。"
    } catch {
      message = error.localizedDescription
    }
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
          Label("任务数据会在 24 小时后自动清理，也可以在结果区立即删除。", systemImage: "clock.arrow.circlepath")
          Label("原始文件不会被删除或覆盖。", systemImage: "checkmark.shield")
        }
        .font(.caption)
        .foregroundStyle(TransallTheme.inkSoft)

        if !settings.message.isEmpty {
          Text(settings.message)
            .font(.caption)
            .foregroundStyle(TransallTheme.inkSoft)
            .textSelection(.enabled)
        }

        HStack {
          Spacer()
          Button(settings.isSaving ? "正在保存" : "保存并应用") {
            Task { await settings.save(appModel: appModel) }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(settings.isSaving)
        }
      }
      .padding(24)
    }
    .frame(width: 540)
    .frame(minHeight: 560)
    .background(TransallTheme.paper)
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
    let configured = !key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(credential.displayName)
          .font(.callout.weight(.semibold))
        Spacer()
        Label(
          configured ? "已配置" : "未配置",
          systemImage: configured ? "checkmark.circle.fill" : "circle"
        )
        .font(.caption)
        .foregroundStyle(configured ? TransallTheme.source : TransallTheme.muted)
      }

      HStack {
        SecureField("\(credential.displayName) API Key", text: key)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("\(credential.displayName) API Key")

        Button("删除密钥", role: .destructive) {
          settings.pendingRemoval = credential
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!configured || settings.isSaving)
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
