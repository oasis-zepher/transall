import AppKit
import Foundation

/// NSUserUnixTask is the system-supported boundary for user-enabled local conversion
/// scripts. It leaves the app sandbox unchanged and requires a one-time folder selection.
enum OfficeConversionComponent {
  static var requiresSetup: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil && !isInstalled
  }
  static var directory: URL? {
    try? FileManager.default.url(
      for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  }
  static var scriptURL: URL? { directory?.appendingPathComponent("transall-office-v1.sh") }
  static var isInstalled: Bool {
    guard let scriptURL, FileManager.default.isExecutableFile(atPath: scriptURL.path),
      let values = try? scriptURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
      values.isSymbolicLink != true, values.fileSize == script.utf8.count,
      let data = try? Data(contentsOf: scriptURL)
    else { return false }
    return data == Data(script.utf8)
  }
  static let setupMessage = "请在设置中启用 Office 转换组件，只需操作一次。"

  @MainActor static func install() -> String {
    guard let directory else { return "无法读取系统转换组件文件夹。" }
    let panel = NSOpenPanel()
    panel.title = "启用 Office 转换"
    panel.message = "选择此文件夹以保存 Transall 的本机转换组件。只需操作一次。"
    panel.prompt = "启用"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = directory
    guard panel.runModal() == .OK, let selected = panel.url else { return "" }
    guard selected.standardizedFileURL == directory.standardizedFileURL else {
      return "请选择窗口最初显示的 Transall 组件文件夹。"
    }
    let scoped = selected.startAccessingSecurityScopedResource()
    defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
    do {
      let file = selected.appendingPathComponent("transall-office-v1.sh")
      try Data(script.utf8).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return "Office 转换已启用。"
    } catch { return "无法启用 Office 转换：\(error.localizedDescription)" }
  }

  static func run(executable: URL, arguments: [String], directory: URL) async throws -> Data {
    if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
      return try await LocalConversionProcess.run(
        executable, arguments: arguments, directory: directory)
    }
    guard isInstalled, let scriptURL else { throw NativeDocumentError.processing(setupMessage) }
    let operation = try NSUserUnixTask(url: scriptURL)
    let cancel = directory.appendingPathComponent("cancel")
    let log = directory.appendingPathComponent("conversion.log")
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          operation.execute(withArguments: [directory.path, executable.path] + arguments) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        }
        try Task.checkCancellation()
      } onCancel: {
        try? Data().write(to: cancel, options: .atomic)
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw NativeDocumentError.processing("Office 转换未完成，请重试或重新启用转换组件。")
    }
    let size = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= 1_024 * 1_024 else { throw NativeDocumentError.processing("Office 转换输出超过限制。") }
    return (try? Data(contentsOf: log)) ?? Data()
  }

  // Fixed script, verified byte-for-byte before execution; file names remain separate args.
  static let script = #"""
    #!/bin/zsh
    set -u
    work="$1"
    converter="$2"
    shift 2
    "$converter" "$@" >"$work/conversion.log" 2>&1 &
    child=$!
    stop_child() {
      kill -TERM "$child" 2>/dev/null || true
      /bin/sleep 0.2
      kill -KILL "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    }
    trap 'stop_child; exit 130' TERM INT HUP
    for ((i=0; i<1200; i++)); do
      if ! kill -0 "$child" 2>/dev/null; then
        wait "$child"
        exit $?
      fi
      if [[ -f "$work/cancel" ]]; then
        stop_child
        exit 130
      fi
      bytes=$(/usr/bin/stat -f %z "$work/conversion.log" 2>/dev/null || /bin/echo 0)
      if (( bytes > 1048576 )); then
        stop_child
        exit 1
      fi
      /bin/sleep 0.1
    done
    stop_child
    exit 1
    """# + "\n"
}
