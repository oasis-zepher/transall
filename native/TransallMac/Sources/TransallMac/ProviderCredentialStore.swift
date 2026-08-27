import Foundation
import Security

enum ProviderCredential: String, CaseIterable, Identifiable, Sendable {
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

enum ProviderCredentialValidationError: LocalizedError, Equatable, Sendable {
  case missing
  case invalidCharacters
  case tooLong

  var errorDescription: String? {
    switch self {
    case .missing:
      "API Key 不能为空。"
    case .invalidCharacters:
      "API Key 必须是单行文字，不能包含换行符或控制字符。"
    case .tooLong:
      "API Key 不能超过 4,096 字节。"
    }
  }
}

enum ProviderCredentialPolicy {
  static let maximumUTF8Bytes = 4_096

  static func normalizedValue(_ rawValue: String, allowingEmpty: Bool) throws -> String {
    let hasInvalidCharacter = rawValue.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
    }
    guard !hasInvalidCharacter else {
      throw ProviderCredentialValidationError.invalidCharacters
    }

    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      if allowingEmpty { return "" }
      throw ProviderCredentialValidationError.missing
    }
    guard value.utf8.count <= maximumUTF8Bytes else {
      throw ProviderCredentialValidationError.tooLong
    }
    return value
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

protocol ProviderCredentialStoring: Sendable {
  func value(for credential: ProviderCredential) throws -> String
  func setValue(_ value: String, for credential: ProviderCredential) throws
}

struct KeychainClient: @unchecked Sendable {
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

struct ProviderCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
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
    let normalized = try ProviderCredentialPolicy.normalizedValue(value, allowingEmpty: true)
    if normalized.isEmpty {
      try removeValue(for: credential)
      return
    }

    do {
      try storeValue(normalized, for: credential, dataProtection: true)
      try deleteLegacyValue(for: credential)
    } catch ProviderCredentialStoreError.keychain(let status)
      where status == errSecMissingEntitlement
    {
      try storeValue(normalized, for: credential, dataProtection: false)
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
    guard let data, let value = String(data: data, encoding: .utf8) else {
      throw ProviderCredentialStoreError.keychain(errSecDecode)
    }
    return value
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

struct ProviderCredentialStatusSnapshot: Sendable {
  let configured: [ProviderCredential: Bool]
  let errors: [ProviderCredential: String]
}

enum ProviderCredentialTransactionError: Error, Sendable {
  case save(
    saveError: String, previousValues: [ProviderCredential: String],
    actualValues: [ProviderCredential: String]?, reconciliationError: String?,
    rollbackErrors: [String]
  )
  case removal(
    credential: ProviderCredential, removalError: String,
    actualValues: [ProviderCredential: String]?, reconciliationError: String?
  )
}

actor ProviderCredentialWorker {
  static let shared = ProviderCredentialWorker(store: ProviderCredentialStore.shared)

  private let store: any ProviderCredentialStoring

  init(store: any ProviderCredentialStoring) {
    self.store = store
  }

  func value(for credential: ProviderCredential) throws -> String {
    try store.value(for: credential)
  }

  func readStoredValues() throws -> [ProviderCredential: String] {
    var values: [ProviderCredential: String] = [:]
    for credential in ProviderCredential.allCases {
      values[credential] = try store.value(for: credential)
    }
    return values
  }

  func status() -> ProviderCredentialStatusSnapshot {
    var configured: [ProviderCredential: Bool] = [:]
    var errors: [ProviderCredential: String] = [:]
    for credential in ProviderCredential.allCases {
      do {
        let value = try store.value(for: credential)
        configured[credential] =
          !(try ProviderCredentialPolicy.normalizedValue(value, allowingEmpty: true)).isEmpty
      } catch {
        configured[credential] = false
        errors[credential] = error.localizedDescription
      }
    }
    return ProviderCredentialStatusSnapshot(configured: configured, errors: errors)
  }

  func save(
    _ values: [ProviderCredential: String],
    replacing previousValues: [ProviderCredential: String]
  ) throws -> [ProviderCredential: String] {
    let changed = ProviderCredential.allCases.filter { values[$0] != previousValues[$0] }
    var attempted: [ProviderCredential] = []
    do {
      for credential in changed {
        attempted.append(credential)
        try store.setValue(values[credential] ?? "", for: credential)
      }
      return values
    } catch {
      let saveError = error.localizedDescription
      var rollbackErrors: [String] = []
      for credential in attempted.reversed() {
        do {
          try store.setValue(previousValues[credential] ?? "", for: credential)
        } catch {
          rollbackErrors.append("\(credential.displayName)：\(error.localizedDescription)")
        }
      }
      let actualValues: [ProviderCredential: String]?
      let reconciliationError: String?
      do {
        actualValues = try readStoredValues()
        reconciliationError = nil
      } catch {
        actualValues = nil
        reconciliationError = error.localizedDescription
      }
      throw ProviderCredentialTransactionError.save(
        saveError: saveError, previousValues: previousValues, actualValues: actualValues,
        reconciliationError: reconciliationError,
        rollbackErrors: rollbackErrors)
    }
  }

  func remove(
    _ credential: ProviderCredential, from previousValues: [ProviderCredential: String]
  ) throws -> [ProviderCredential: String] {
    do {
      try store.setValue("", for: credential)
      var values = previousValues
      values[credential] = ""
      return values
    } catch {
      let removalError = error.localizedDescription
      let actualValues: [ProviderCredential: String]?
      let reconciliationError: String?
      do {
        actualValues = try readStoredValues()
        reconciliationError = nil
      } catch {
        actualValues = nil
        reconciliationError = error.localizedDescription
      }
      throw ProviderCredentialTransactionError.removal(
        credential: credential, removalError: removalError, actualValues: actualValues,
        reconciliationError: reconciliationError)
    }
  }
}
