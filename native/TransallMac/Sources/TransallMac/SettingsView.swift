import Combine
import SwiftUI

@MainActor
private final class ProviderSettingsModel: ObservableObject {
  @Published var deepseekKey: String
  @Published var openAIKey: String
  @Published var message = ""
  @Published var isSaving = false

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
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @StateObject private var settings = ProviderSettingsModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("翻译服务")
          .font(.system(.title2, design: .serif, weight: .semibold))
        Text("密钥保存在 macOS 钥匙串中，不写入项目文件或任务日志。")
          .font(.caption)
          .foregroundStyle(TransallTheme.muted)
      }

      VStack(alignment: .leading, spacing: 12) {
        SecureField("DeepSeek API Key", text: $settings.deepseekKey)
          .textFieldStyle(.roundedBorder)
        SecureField("OpenAI API Key", text: $settings.openAIKey)
          .textFieldStyle(.roundedBorder)
      }

      Text("只有执行翻译任务时，需要翻译的文档内容才会发送给你选择的服务商。")
        .font(.caption)
        .foregroundStyle(TransallTheme.warning)

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
    .background(TransallTheme.paper)
  }
}
