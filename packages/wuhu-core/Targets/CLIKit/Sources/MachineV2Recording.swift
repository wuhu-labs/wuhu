#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Fetch
import struct FetchExchangeRecording.ExchangeRecording
import class FetchExchangeRecording.FetchExchangeRecorder
import struct FetchExchangeRecording.RecordedEffect
import struct FetchExchangeRecording.RecordedExchange
import struct HTTPTypes.HTTPField
import enum JSONValue.JSONValue
import typealias Serve.Handler

actor MachineV2Recording {
  let directory: URL
  var count = 0
  let limit = 4096

  init(root: URL) throws {
    var state = stat()
    guard lstat(root.path, &state) == 0, state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFDIR, state.st_mode & 0o777 == 0o700 else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Recording requires an existing owner-private 0700 directory") }
    directory = root.appendingPathComponent("agent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  nonisolated func handler(_ live: @escaping Handler) -> Handler {
    { try await self.record($0, live: live) }
  }

  func record(_ request: Request, live: @escaping Handler) async throws -> Response {
    guard count < limit else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Diagnostic recording capacity exhausted") }
    let index = count; count += 1
    let path = directory.appendingPathComponent("exchange-" + String(repeating: "0", count: max(0, 4 - String(index).count)) + String(index) + ".json")
    let data = try await request.body?.bytes(upTo: 1024 * 1024)
    var original = request
    if let data { original.body = .bytes(data, contentType: request.body?.contentType) }
    var safe = original
    var headers = RequestHeaders()
    for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID", "Content-Type"] { headers[name] = request.headers[name] }
    safe.headers = headers
    let safeData = try data.map { try sanitized($0) }
    if let safeData { safe.body = .bytes(safeData, contentType: request.body?.contentType) }
    let head = RecordedExchange.Head(method: safe.method.rawValue, url: safe.url.absoluteString, headers: Dictionary(uniqueKeysWithValues: safe.headers.fields.map { ($0.name.rawName.lowercased(), $0.value) }), body: safeData)
    try write(ExchangeRecording(exchanges: [], effects: [RecordedEffect("requestPending", input: ["method": head.method!, "url": head.url!, "requestBody": head.body?.base64EncodedString() ?? ""])]), to: path, new: true)
    do {
      let response = try await live(original)
      let bytes = try await response.body.bytes(upTo: 1024 * 1024)
      var safeHeaders = Headers()
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID", "X-Wuhu-Agent-Instance", "Content-Type"] {
        let field = HTTPField.Name(name)!
        safeHeaders[field] = response.headers[field]
      }
      let safeResponse = Response(status: response.status, headers: safeHeaders, body: .bytes(try sanitized(bytes), contentType: response.body.contentType))
      let recorder = FetchExchangeRecorder(live: FetchClient { _ in safeResponse }, bodyLimit: 1024 * 1024, exchangeLimit: 1)
      _ = try await recorder.client(safe)
      try await recorder.effect(RecordedEffect("handlerResponse", output: ["status": String(response.status.code)]))
      try write(await recorder.recording(), to: path, new: false)
      return Response(status: response.status, headers: response.headers, body: .bytes(bytes, contentType: response.body.contentType))
    } catch {
      try write(ExchangeRecording(exchanges: [], effects: [RecordedEffect("handlerFailure", input: ["method": head.method!, "url": head.url!], output: ["code": error is CancellationError ? "cancelled" : "handlerFailed"])]), to: path, new: false)
      throw error
    }
  }

  func write(_ recording: ExchangeRecording, to path: URL, new: Bool) throws {
    let data = try JSONEncoder().encode(recording)
    if new { try data.write(to: path, options: .withoutOverwriting) }
    else { try data.write(to: path, options: .atomic) }
    guard chmod(path.path, 0o600) == 0 else { throw MachineV2RuntimeError(.invalidConfiguration) }
  }

  func sanitized(_ data: Data) throws -> Data {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return data }
    func scrub(_ value: JSONValue) -> JSONValue {
      switch value {
      case .object(let fields):
        return .object(fields.mapValues { scrub($0) }.filter { key, _ in
          let key = key.lowercased()
          return !["sessioncredential", "secretvalues", "env", "token", "pubkey", "key", "signature", "password", "credential", "authorization"].contains(key)
        })
      case .array(let values): return .array(values.map(scrub))
      default: return value
      }
    }
    return try JSONEncoder().encode(scrub(json))
  }
}
