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

@MainActor
protocol ProviderCredentialStoring {
  func value(for credential: ProviderCredential) throws -> String
  func setValue(_ value: String, for credential: ProviderCredential) throws
}

@MainActor
struct KeychainClient {
  let copyMatching: ([String: Any]) -> (OSStatus, Data?)
  let update: ([String: Any], [String: Any]) -> OSStatus
  let add: ([String: Any]) -> OSStatus
  let delete: ([String: Any]) -> OSStatus

  static let system = KeychainClient(
    copyMatching: { query in
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      return (status, result as? Data)
    },
    update: { query, attributes in
      SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    },
    add: { item in
      SecItemAdd(item as CFDictionary, nil)
    },
    delete: { query in
      SecItemDelete(query as CFDictionary)
    })
}

@MainActor
struct ProviderCredentialStore: ProviderCredentialStoring {
  static let shared = ProviderCredentialStore()
  private static let service = "com.transall.mac.translation-providers"
  private let client: KeychainClient

  init(client: KeychainClient? = nil) {
    self.client = client ?? .system
  }

  func value(for credential: ProviderCredential) throws -> String {
    var query = Self.baseQuery(for: credential, dataProtection: true)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, data) = client.copyMatching(query)
    switch status {
    case errSecSuccess:
      let value = try decodedValue(data)
      try deleteLegacyValue(for: credential)
      return value
    case errSecItemNotFound:
      return try migrateLegacyValue(for: credential)
    case errSecMissingEntitlement:
      return try legacyValue(for: credential)
    default:
      throw ProviderCredentialStoreError.keychain(status)
    }
  }

  func setValue(_ value: String, for credential: ProviderCredential) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try removeValue(for: credential)
      return
    }

    do {
      try storeValue(trimmed, for: credential, dataProtection: true)
      try deleteLegacyValue(for: credential)
    } catch ProviderCredentialStoreError.keychain(let status)
      where status == errSecMissingEntitlement
    {
      try storeValue(trimmed, for: credential, dataProtection: false)
    }
  }

  static func baseQuery(
    for credential: ProviderCredential, dataProtection: Bool
  ) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: credential.rawValue,
    ]
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }

  private func decodedValue(_ data: Data?) throws -> String {
    guard let data else { throw ProviderCredentialStoreError.keychain(errSecDecode) }
    return String(decoding: data, as: UTF8.self)
  }

  private func legacyValue(for credential: ProviderCredential) throws -> String {
    var query = Self.baseQuery(for: credential, dataProtection: false)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, data) = client.copyMatching(query)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess else {
      throw ProviderCredentialStoreError.keychain(status)
    }
    return try decodedValue(data)
  }

  private func migrateLegacyValue(for credential: ProviderCredential) throws -> String {
    let value = try legacyValue(for: credential)
    guard !value.isEmpty else { return "" }
    do {
      try storeValue(value, for: credential, dataProtection: true)
      try deleteLegacyValue(for: credential)
    } catch ProviderCredentialStoreError.keychain(let status)
      where status == errSecMissingEntitlement
    {
      return value
    }
    return value
  }

  private func removeValue(for credential: ProviderCredential) throws {
    let status = client.delete(Self.baseQuery(for: credential, dataProtection: true))
    switch status {
    case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
      try deleteLegacyValue(for: credential)
    default:
      throw ProviderCredentialStoreError.keychain(status)
    }
  }

  private func deleteLegacyValue(for credential: ProviderCredential) throws {
    let status = client.delete(Self.baseQuery(for: credential, dataProtection: false))
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProviderCredentialStoreError.keychain(status)
    }
  }

  private func storeValue(
    _ value: String, for credential: ProviderCredential, dataProtection: Bool
  ) throws {
    let query = Self.baseQuery(for: credential, dataProtection: dataProtection)
    let data = Data(value.utf8)
    var update: [String: Any] = [kSecValueData as String: data]
    if dataProtection {
      update[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    let updateStatus = client.update(query, update)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderCredentialStoreError.keychain(updateStatus)
    }

    var item = query
    item[kSecValueData as String] = data
    if dataProtection {
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    let addStatus = client.add(item)
    guard addStatus == errSecSuccess else {
      throw ProviderCredentialStoreError.keychain(addStatus)
    }
  }
}
