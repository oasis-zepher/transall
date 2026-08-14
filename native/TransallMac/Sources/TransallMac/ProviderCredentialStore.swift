import Foundation
import Security

enum ProviderCredential: String, CaseIterable, Identifiable {
  case deepseek
  case openAI = "openai"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .deepseek: "DeepSeek"
    case .openAI: "OpenAI"
    }
  }

  var environmentVariable: String {
    switch self {
    case .deepseek: "DEEPSEEK_API_KEY"
    case .openAI: "OPENAI_API_KEY"
    }
  }
}

enum ProviderCredentialStoreError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "无法访问钥匙串（错误 \(status)）。"
    }
  }
}

protocol ProviderCredentialStoring {
  func value(for credential: ProviderCredential) throws -> String
  func setValue(_ value: String, for credential: ProviderCredential) throws
}

struct ProviderCredentialStore: ProviderCredentialStoring {
  static let shared = ProviderCredentialStore()
  private let service = "com.transall.mac.translation-providers"

  func value(for credential: ProviderCredential) throws -> String {
    var query = baseQuery(for: credential)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data else {
      throw ProviderCredentialStoreError.keychain(status)
    }
    return String(decoding: data, as: UTF8.self)
  }

  func setValue(_ value: String, for credential: ProviderCredential) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = baseQuery(for: credential)
    if trimmed.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProviderCredentialStoreError.keychain(status)
      }
      return
    }

    let data = Data(trimmed.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderCredentialStoreError.keychain(updateStatus)
    }

    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw ProviderCredentialStoreError.keychain(addStatus)
    }
  }

  private func baseQuery(for credential: ProviderCredential) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: credential.rawValue,
    ]
  }
}
