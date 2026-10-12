import Foundation
import Testing

@testable import TransallMac

struct LocalCredentialTests {
  @Test
  func savedKeysSurviveNewStoreAndWorkerWithoutAuthorization() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = LocalProviderCredentialStore(directory: directory)
    try first.setValue("test-deepseek-key", for: .deepseek)
    try first.setValue("test-openai-key", for: .openAI)
    let restarted = ProviderCredentialWorker(
      store: LocalProviderCredentialStore(directory: directory))
    let status = await restarted.status()
    #expect(status.configured[.deepseek] == true)
    #expect(status.configured[.openAI] == true)
    #expect(status.requiresAuthorization.isEmpty)
    #expect(status.errors.isEmpty)
    #expect(try await restarted.value(for: .deepseek) == "test-deepseek-key")
    let file = directory.appendingPathComponent("provider-credentials.json")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    try first.setValue("", for: .deepseek)
    let third = LocalProviderCredentialStore(directory: directory)
    #expect(try third.value(for: .deepseek).isEmpty)
    #expect(try third.value(for: .openAI) == "test-openai-key")
  }

  @Test
  func corruptedOrLinkedConfigIsNotOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("provider-credentials.json")
    let original = Data("broken configuration".utf8)
    try original.write(to: file)
    let store = LocalProviderCredentialStore(directory: directory)
    #expect(throws: (any Error).self) { try store.setValue("new-key", for: .deepseek) }
    #expect(try Data(contentsOf: file) == original)
    try FileManager.default.removeItem(at: file)
    let target = directory.appendingPathComponent("untouched")
    try original.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: (any Error).self) { try store.value(for: .deepseek) }
    #expect(throws: (any Error).self) { try store.setValue("new-key", for: .deepseek) }
    #expect(try Data(contentsOf: target) == original)
  }
}
