import Combine
import Foundation

@MainActor
final class BackendService: ObservableObject {
  enum State: Equatable {
    case starting
    case running
    case failed(String)

    var label: String {
      switch self {
      case .starting: "正在启动本地引擎"
      case .running: "本地引擎已连接"
      case .failed: "本地引擎不可用"
      }
    }
  }

  @Published private(set) var state: State = .starting
  @Published private(set) var serviceLog: [String] = []

  let client: APIClient
  private var process: Process?
  private var ownsProcess = false

  init() {
    let configured = ProcessInfo.processInfo.environment["TRANSALL_BACKEND_URL"]
      .flatMap(URL.init(string:))
    client = APIClient(baseURL: configured ?? URL(string: "http://127.0.0.1:8765")!)
  }

  func start() async {
    state = .starting
    if await client.ping() {
      state = .running
      appendLog("已连接现有本地服务。")
      return
    }

    do {
      try launchProcess()
      for _ in 0..<60 {
        if await client.ping() {
          state = .running
          appendLog("本地文档引擎已启动。")
          return
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      throw BackendLaunchError.timeout
    } catch {
      state = .failed(error.localizedDescription)
      appendLog(error.localizedDescription)
    }
  }

  func stop() {
    guard ownsProcess, let process, process.isRunning else { return }
    process.terminate()
    self.process = nil
    ownsProcess = false
  }

  func applyCredentialChanges() async -> String {
    guard ownsProcess else {
      return "密钥已保存到钥匙串。当前连接的是外部服务，重启该服务后生效。"
    }
    stop()
    try? await Task.sleep(for: .milliseconds(350))
    await start()
    switch state {
    case .running:
      return "密钥已保存到钥匙串，本地引擎已重新启动。"
    case .starting:
      return "密钥已保存，正在重新启动本地引擎。"
    case .failed(let message):
      return "密钥已保存，但本地引擎重启失败：\(message)"
    }
  }

  private func launchProcess() throws {
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "transall-backend") {
      try run(executable: bundled, arguments: [])
      return
    }

    let root = try projectRoot()
    let uv = try uvExecutable()
    let requirements = root.appendingPathComponent("requirements.lock")
    try run(
      executable: uv,
      arguments: [
        "run",
        "--with-requirements", requirements.path,
        "python", "-m", "app.native_entry",
      ],
      workingDirectory: root
    )
  }

  private func run(executable: URL, arguments: [String], workingDirectory: URL? = nil) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory

    var environment = ProcessInfo.processInfo.environment
    environment["TRANSALL_HOST"] = client.baseURL.host ?? "127.0.0.1"
    environment["TRANSALL_PORT"] = String(client.baseURL.port ?? 8765)
    environment["DOCWORK_DATA_DIR"] = try applicationDataDirectory().path
    for credential in ProviderCredential.allCases {
      if let value = try? ProviderCredentialStore.shared.value(for: credential), !value.isEmpty {
        environment[credential.environmentVariable] = value
      }
    }
    process.environment = environment

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor [weak self] in
        self?.appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    process.terminationHandler = { [weak self] process in
      Task { @MainActor [weak self] in
        guard let self, self.ownsProcess, process.terminationStatus != 0 else { return }
        self.state = .failed("本地引擎意外退出（\(process.terminationStatus)）。")
      }
    }

    try process.run()
    self.process = process
    ownsProcess = true
  }

  private func projectRoot() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment["TRANSALL_PROJECT_ROOT"] {
      let url = URL(fileURLWithPath: configured, isDirectory: true)
      if isProjectRoot(url) { return url }
    }

    var candidate = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<6 {
      if isProjectRoot(candidate) { return candidate }
      candidate.deleteLastPathComponent()
    }
    throw BackendLaunchError.projectRootMissing
  }

  private func isProjectRoot(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent("app/main.py").path)
      && FileManager.default.fileExists(
        atPath: url.appendingPathComponent("requirements.lock").path)
  }

  private func uvExecutable() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [
      environment["TRANSALL_UV_EXECUTABLE"],
      "/opt/homebrew/bin/uv",
      "/usr/local/bin/uv",
    ].compactMap { $0 }
    if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
      return URL(fileURLWithPath: path)
    }
    throw BackendLaunchError.uvMissing
  }

  private func applicationDataDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = base.appendingPathComponent("Transall/Data", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func appendLog(_ text: String) {
    guard !text.isEmpty else { return }
    serviceLog.append(text)
    if serviceLog.count > 80 {
      serviceLog.removeFirst(serviceLog.count - 80)
    }
  }
}

private enum BackendLaunchError: LocalizedError {
  case timeout
  case projectRootMissing
  case uvMissing

  var errorDescription: String? {
    switch self {
    case .timeout:
      "本地引擎启动超时。"
    case .projectRootMissing:
      "找不到 Transall 后端目录；可设置 TRANSALL_PROJECT_ROOT。"
    case .uvMissing:
      "找不到 uv；请安装 uv 或设置 TRANSALL_UV_EXECUTABLE。"
    }
  }
}
