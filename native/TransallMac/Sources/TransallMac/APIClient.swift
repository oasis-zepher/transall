import Foundation

enum APIClientError: LocalizedError {
  case invalidResponse
  case server(status: Int, detail: String)
  case invalidPayload

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "本地服务返回了无效响应。"
    case .server(_, let detail):
      return detail
    case .invalidPayload:
      return "无法生成任务参数。"
    }
  }
}

final class APIClient {
  let baseURL: URL
  private let session: URLSession
  private let decoder: JSONDecoder

  init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
    decoder = JSONDecoder()
  }

  func ping() async -> Bool {
    do {
      let _: CapabilitiesResponse = try await get("/api/capabilities")
      return true
    } catch {
      return false
    }
  }

  func capabilities() async throws -> CapabilitiesResponse {
    try await get("/api/capabilities")
  }

  func diagnostics() async throws -> DiagnosticsResponse {
    try await get("/api/diagnostics")
  }

  func providers() async throws -> ProvidersResponse {
    try await get("/api/config/providers")
  }

  func preflight(route: RouteDefinition, files: [SelectedDocument], options: [String: Any])
    async throws -> PreflightResponse
  {
    let payload: [String: Any] = [
      "source_format": route.source,
      "target_format": route.target,
      "kind": route.kind,
      "files": files.map { ["name": $0.name, "size": $0.size] },
      "options": options,
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    return try await request(
      "/api/preflight", method: "POST", body: body, contentType: "application/json")
  }

  func createJob(kind: String, files: [SelectedDocument], options: [String: Any]) async throws
    -> JobResponse
  {
    guard JSONSerialization.isValidJSONObject(options) else {
      throw APIClientError.invalidPayload
    }
    let optionsData = try JSONSerialization.data(withJSONObject: options)
    let optionsText = String(decoding: optionsData, as: UTF8.self)
    let boundary = "Transall-\(UUID().uuidString)"
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-upload-\(UUID().uuidString)")
    let writer = try MultipartWriter(url: temporary, boundary: boundary)
    defer {
      writer.close()
      try? FileManager.default.removeItem(at: temporary)
    }

    try writer.appendField(name: "kind", value: kind)
    try writer.appendField(name: "options", value: optionsText)
    for file in files {
      try writer.appendFile(field: "files", document: file)
    }
    try writer.finish()
    writer.close()

    var request = URLRequest(url: endpoint("/api/jobs"))
    request.httpMethod = "POST"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.upload(for: request, fromFile: temporary)
    return try decodeResponse(data: data, response: response)
  }

  func job(id: String) async throws -> JobResponse {
    try await get("/api/jobs/\(id)")
  }

  func cancelJob(id: String) async throws -> JobResponse {
    try await request("/api/jobs/\(id)/cancel", method: "POST")
  }

  func deleteJob(id: String) async throws {
    let _: DeleteJobResponse = try await request("/api/jobs/\(id)", method: "DELETE")
  }

  func previewPages(jobID: String) async throws -> PreviewResponse {
    try await get("/api/jobs/\(jobID)/preview/pages")
  }

  func absoluteURL(for path: String) -> URL? {
    URL(string: path, relativeTo: baseURL)?.absoluteURL
  }

  func download(jobID: String, to destination: URL) async throws {
    let (temporary, response) = try await session.download(
      from: endpoint("/api/jobs/\(jobID)/download"))
    try validate(response: response, data: nil)
    let manager = FileManager.default
    if manager.fileExists(atPath: destination.path) {
      try manager.removeItem(at: destination)
    }
    try manager.moveItem(at: temporary, to: destination)
  }

  private func get<T: Decodable>(_ path: String) async throws -> T {
    try await request(path, method: "GET")
  }

  private func request<T: Decodable>(
    _ path: String,
    method: String,
    body: Data? = nil,
    contentType: String? = nil
  ) async throws -> T {
    var request = URLRequest(url: endpoint(path))
    request.httpMethod = method
    request.httpBody = body
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
    try validate(response: response, data: data)
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw APIClientError.invalidResponse
    }
  }

  private func validate(response: URLResponse, data: Data?) throws {
    guard let response = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      let detail = data.flatMap(Self.errorDetail) ?? "本地服务请求失败（HTTP \(response.statusCode)）。"
      throw APIClientError.server(status: response.statusCode, detail: detail)
    }
  }

  private func endpoint(_ path: String) -> URL {
    URL(string: path, relativeTo: baseURL)!.absoluteURL
  }

  private static func errorDetail(_ data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = object["detail"] as? String
    else {
      return nil
    }
    return detail
  }
}

private struct DeleteJobResponse: Decodable {
  let deleted: Bool
}

private final class MultipartWriter {
  private let boundary: String
  private let handle: FileHandle
  private var isClosed = false

  init(url: URL, boundary: String) throws {
    self.boundary = boundary
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
  }

  func appendField(name: String, value: String) throws {
    try append("--\(boundary)\r\n")
    try append("Content-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n")
    try append(value)
    try append("\r\n")
  }

  func appendFile(field: String, document: SelectedDocument) throws {
    let accessing = document.url.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        document.url.stopAccessingSecurityScopedResource()
      }
    }

    try append("--\(boundary)\r\n")
    try append(
      "Content-Disposition: form-data; name=\"\(escaped(field))\"; filename=\"\(escaped(document.name))\"\r\n"
    )
    try append("Content-Type: application/octet-stream\r\n\r\n")

    let source = try FileHandle(forReadingFrom: document.url)
    defer { try? source.close() }
    while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      try handle.write(contentsOf: chunk)
    }
    try append("\r\n")
  }

  func finish() throws {
    try append("--\(boundary)--\r\n")
    try handle.synchronize()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    try? handle.close()
  }

  private func append(_ value: String) throws {
    try handle.write(contentsOf: Data(value.utf8))
  }

  private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "_")
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
  }
}
