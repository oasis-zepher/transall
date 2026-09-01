import Foundation

enum PrivacyPolicyConfiguration {
  static let infoDictionaryKey = "TransallPrivacyPolicyURL"

  static var appURL: URL? {
    url(from: Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey))
  }

  static func url(from rawValue: Any?) -> URL? {
    guard let rawValue = rawValue as? String else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == rawValue, !value.isEmpty, !value.contains("$(") else { return nil }
    guard let components = URLComponents(string: value) else { return nil }
    guard components.scheme?.lowercased() == "https" else { return nil }
    guard components.user == nil, components.password == nil else { return nil }
    guard let host = components.host?.lowercased(), isPublicHost(host) else { return nil }
    if let port = components.port, !(1...65_535).contains(port) { return nil }
    return components.url
  }

  private static func isPublicHost(_ host: String) -> Bool {
    guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
    guard host.unicodeScalars.allSatisfy(allowed.contains), host.contains(where: \.isLetter)
    else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
    else { return false }
    let reservedSuffixes = [".example", ".invalid", ".local", ".localhost", ".test"]
    let documentationHosts = ["example.com", "example.net", "example.org"]
    let usesDocumentationHost = documentationHosts.contains {
      host == $0 || host.hasSuffix(".\($0)")
    }
    return host != "localhost" && !usesDocumentationHost
      && !reservedSuffixes.contains { host.hasSuffix($0) }
  }
}
