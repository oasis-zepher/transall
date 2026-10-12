import Foundation
import LocalAuthentication
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

  var requiresUserInteraction: Bool {
    if case .keychain(errSecInteractionNotAllowed) = self { return true }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      status == errSecInteractionNotAllowed
        ? "系统尚未允许此版本读取已保存的密钥，请在设置中授权一次。应用不会自动弹出钥匙串窗口。"
        : "无法访问钥匙串（错误 \(status)）。"
    }
  }
}

protocol ProviderCredentialStoring: Sendable {
  func value(for credential: ProviderCredential) throws -> String
  func value(for credential: ProviderCredential, allowingInteraction: Bool) throws -> String
  func setValue(_ value: String, for credential: ProviderCredential) throws
}

extension ProviderCredentialStoring {
  func value(for credential: ProviderCredential, allowingInteraction: Bool) throws -> String {
    try value(for: credential)
  }
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
    try value(for: credential, allowingInteraction: true)
  }

  func value(for credential: ProviderCredential, allowingInteraction: Bool) throws -> String {
    var query = Self.readQuery(
      for: credential, dataProtection: true, allowingInteraction: allowingInteraction)
    let (status, data) = client.copyMatching(query)
    switch status {
    case errSecSuccess:
      return try decodedValue(data)
    case errSecItemNotFound, errSecMissingEntitlement:
      if !allowingInteraction {
        var presenceQuery = Self.baseQuery(for: credential, dataProtection: false)
        presenceQuery[kSecReturnAttributes as String] = true
        presenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let (presenceStatus, _) = client.copyMatching(presenceQuery)
        if presenceStatus == errSecItemNotFound { return "" }
        if presenceStatus == errSecSuccess {
          throw ProviderCredentialStoreError.keychain(errSecInteractionNotAllowed)
        }
        throw ProviderCredentialStoreError.keychain(presenceStatus)
      }
      query = Self.readQuery(
        for: credential, dataProtection: false, allowingInteraction: allowingInteraction)
      let (legacyStatus, legacyData) = client.copyMatching(query)
      if legacyStatus == errSecItemNotFound { return "" }
      guard legacyStatus == errSecSuccess else {
        throw ProviderCredentialStoreError.keychain(legacyStatus)
      }
      return try decodedValue(legacyData)
    default:
      throw ProviderCredentialStoreError.keychain(status)
    }
  }

  private static func readQuery(
    for credential: ProviderCredential, dataProtection: Bool, allowingInteraction: Bool
  ) -> [String: Any] {
    var query = baseQuery(for: credential, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !allowingInteraction
    query[kSecUseAuthenticationContext as String] = context
    return query
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
  var requiresAuthorization: Set<ProviderCredential> = []
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
  static let shared = ProviderCredentialWorker(store: LocalProviderCredentialStore.shared)

  private let store: any ProviderCredentialStoring
  // Reuse successful reads during this process; the local store persists across launches.
  private var cachedValues: [ProviderCredential: String] = [:]

  init(store: any ProviderCredentialStoring) {
    self.store = store
  }

  func value(for credential: ProviderCredential, allowingInteraction: Bool = true) throws -> String
  {
    if let cached = cachedValues[credential] { return cached }
    let value = try store.value(for: credential, allowingInteraction: allowingInteraction)
    if !value.isEmpty { cachedValues[credential] = value }
    return value
  }

  func readStoredValues(
    allowingInteraction: Bool = true, refreshing: Bool = false
  ) throws -> [ProviderCredential: String] {
    if refreshing { cachedValues.removeAll() }
    var values: [ProviderCredential: String] = [:]
    for credential in ProviderCredential.allCases {
      values[credential] = try value(for: credential, allowingInteraction: allowingInteraction)
    }
    return values
  }

  func status() -> ProviderCredentialStatusSnapshot {
    var configured: [ProviderCredential: Bool] = [:]
    var errors: [ProviderCredential: String] = [:]
    var requiresAuthorization: Set<ProviderCredential> = []
    for credential in ProviderCredential.allCases {
      do {
        let value = try value(for: credential, allowingInteraction: false)
        configured[credential] =
          !(try ProviderCredentialPolicy.normalizedValue(value, allowingEmpty: true)).isEmpty
      } catch {
        configured[credential] = false
        errors[credential] = error.localizedDescription
        if case ProviderCredentialStoreError.keychain(errSecInteractionNotAllowed) = error {
          requiresAuthorization.insert(credential)
        }
      }
    }
    return ProviderCredentialStatusSnapshot(
      configured: configured, errors: errors,
      requiresAuthorization: requiresAuthorization)
  }

  func save(
    _ values: [ProviderCredential: String],
    replacing previousValues: [ProviderCredential: String]
  ) throws -> [ProviderCredential: String] {
    let changed = ProviderCredential.allCases.filter { values[$0] != previousValues[$0] }
    var attempted: [ProviderCredential] = []
    for credential in changed { cachedValues[credential] = nil }
    do {
      for credential in changed {
        attempted.append(credential)
        try store.setValue(values[credential] ?? "", for: credential)
      }
      for credential in changed { cachedValues[credential] = values[credential] }
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
        actualValues = try readStoredValues(allowingInteraction: false, refreshing: true)
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
    cachedValues[credential] = nil
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
        actualValues = try readStoredValues(allowingInteraction: false, refreshing: true)
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

// User-selected local storage: owner-only directory and file, with no Keychain lookup.
final class LocalProviderCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
  static let shared = LocalProviderCredentialStore()
  private static let lock = NSLock()
  private let directory: URL
  private let filename = "provider-credentials.json"

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Transall/Configuration", isDirectory: true)
  }

  func value(for credential: ProviderCredential) throws -> String {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let descriptor = try openDirectory()
    defer { close(descriptor) }
    return try readValues(in: descriptor)[credential.rawValue] ?? ""
  }

  func setValue(_ value: String, for credential: ProviderCredential) throws {
    let normalized = try ProviderCredentialPolicy.normalizedValue(value, allowingEmpty: true)
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let directoryFD = try openDirectory()
    defer { close(directoryFD) }
    var values = try readValues(in: directoryFD)
    values[credential.rawValue] = normalized.isEmpty ? nil : normalized
    let data = try JSONEncoder().encode(values)
    let temporary = ".credentials-\(UUID().uuidString)"
    let descriptor = openat(
      directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw storageError() }
    defer {
      close(descriptor)
      unlinkat(directoryFD, temporary, 0)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw storageError() }
        offset += count
      }
    }
    guard fsync(descriptor) == 0,
      renameat(directoryFD, temporary, directoryFD, filename) == 0
    else { throw storageError() }
  }

  private func openDirectory() throws -> Int32 {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw storageError() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), fchmod(descriptor, 0o700) == 0
    else {
      close(descriptor)
      throw storageError()
    }
    return descriptor
  }

  private func readValues(in directoryFD: Int32) throws -> [String: String] {
    let descriptor = openat(directoryFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 && errno == ENOENT { return [:] }
    guard descriptor >= 0 else { throw storageError() }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= 32_768,
      fchmod(descriptor, 0o600) == 0
    else { throw storageError() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw storageError() }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= 32_768 else { throw storageError() }
    }
    do {
      let values = try JSONDecoder().decode([String: String].self, from: data)
      for value in values.values {
        _ = try ProviderCredentialPolicy.normalizedValue(value, allowingEmpty: true)
      }
      return values
    } catch {
      throw NSError(
        domain: "TransallCredentials", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "本机密钥配置损坏，未覆盖已有内容。"
        ])
    }
  }

  private func storageError() -> NSError {
    NSError(
      domain: "TransallCredentials", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "无法安全读写本机密钥配置，请检查当前账户的文件权限。"
      ])
  }
}
