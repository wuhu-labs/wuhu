#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Fetch
import FetchURLSession
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import JSONValue

// MARK: - Recording Context

// Fixtures are raw `{url, method, headers, body}` plus response bytes, with
// sensitive header values (`RequestHeaders.setSensitive`) redacted before they
// touch disk. Responses are assumed to be Server-Sent Events.
struct RecordingContext: Sendable {
  let fetchClient: FetchClient
  let webSocketConnector: WebSocketConnector
  private let sockets: SocketRecording?
  private let replaySockets: SocketReplay?
  private let collector: RecordingCollector?
  private let recordDir: URL

  init(name: String, mode: RecordingMode, recordingsRoot: URL, matchIgnoringBodyFields: Set<String> = [], webSocketConnector: WebSocketConnector = .live) {
    self.recordDir = recordingsRoot.appendingPathComponent(name)
    let recordDir = self.recordDir

    switch mode {
    case .recordAll, .recordOnly:
      let collector = RecordingCollector()
      self.collector = collector
      let sockets = SocketRecording()
      self.sockets = sockets
      self.replaySockets = nil
      self.webSocketConnector = sockets.connector(webSocketConnector)
      let realClient = FetchClient.urlSession()

      self.fetchClient = FetchClient { request in
        try await recordRequest(
          request: request,
          realClient: realClient,
          collector: collector,
        )
      }

    case .replay:
      self.collector = nil
      self.sockets = nil
      let replaySockets = SocketReplay(directory: recordDir)
      self.replaySockets = replaySockets
      self.webSocketConnector = replaySockets.connector
      let ledger = ReplayLedger(recordDir: recordDir, ignoredFields: matchIgnoringBodyFields)
      self.fetchClient = FetchClient { request in
        try await replayResponse(request: request, ledger: ledger, recordDir: recordDir)
      }
    }
  }

  func finishSockets() async {
    await sockets?.finish()
    replaySockets?.finish()
  }

  func verifyReplay() throws { try replaySockets?.verify() }

  func flushRecordings() async throws {
    guard let collector else { return }
    try await collector.flush(to: recordDir)
    try sockets?.flush(to: recordDir)
  }
}

// MARK: - Replay Ledger

// Concurrent sessions reach the provider in whatever order the scheduler
// picks, so a fixture is claimed by body, not by arrival index. UUIDs are
// compared up to renaming (kernel-minted ids depend on that same order). JSON
// embedded in a string — tool-call arguments — is compared as the bytes it is:
// those bytes are what a prompt cache keys on. Fields the caller names are
// dropped from both sides: a fixture must not pin a body part the test asserts
// itself.
private actor ReplayLedger {
  private let recordDir: URL
  private let ignoredFields: Set<String>
  private var unclaimed: [(index: Int, body: JSONValue)]?

  init(recordDir: URL, ignoredFields: Set<String>) {
    self.recordDir = recordDir
    self.ignoredFields = ignoredFields
  }

  func claim(_ body: JSONValue) throws -> Int {
    let fixtures = try load()
    guard !fixtures.isEmpty else { throw RecordReplayError.noRecordingsFound(recordDir.lastPathComponent) }
    let wanted = comparable(body)
    guard let position = fixtures.firstIndex(where: { comparable($0.body) == wanted }) else {
      throw RecordReplayError.requestBodyMismatch(
        expected: fixtures[0].body.jsonString(),
        actual: body.jsonString(),
      )
    }
    unclaimed = fixtures.enumerated().filter { $0.offset != position }.map(\.element)
    return fixtures[position].index
  }

  private func comparable(_ body: JSONValue) -> JSONValue {
    guard case var .object(fields) = body, !ignoredFields.isEmpty else { return uuidNormalized(body) }
    for field in ignoredFields { fields.removeValue(forKey: field) }
    return uuidNormalized(.object(fields))
  }

  private func load() throws -> [(index: Int, body: JSONValue)] {
    if let unclaimed { return unclaimed }
    var loaded: [(index: Int, body: JSONValue)] = []
    var index = 1
    while true {
      let file = recordDir.appendingPathComponent("\(index).request.json")
      guard FileManager.default.fileExists(atPath: file.path) else { break }
      loaded.append((index, try JSONDecoder().decode(RecordedRequest.self, from: Data(contentsOf: file)).body))
      index += 1
    }
    unclaimed = loaded
    return loaded
  }
}

private func uuidNormalized(_ body: JSONValue) -> JSONValue {
  let uuidPattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
  var names: [String: String] = [:]
  func walk(_ value: JSONValue) -> JSONValue {
    switch value {
    case .null, .bool, .integer, .number:
      return value
    case let .string(text):
      return .string(text.replacing(uuidPattern) { match in
        let key = match.output.lowercased()
        if let name = names[key] { return name }
        let name = "uuid#\(names.count + 1)"
        names[key] = name
        return name
      })
    case let .array(items):
      return .array(items.map(walk))
    case let .object(fields):
      var sorted = fields
      sorted.removeAll()
      for key in fields.keys.sorted() { sorted[key] = walk(fields[key]!) }
      return .object(sorted)
    }
  }
  return walk(body)
}

// MARK: - Recording Collector

private actor RecordingCollector {
  private var pairs: [(sanitizedRequest: Data, responseBytes: Data)] = []

  func append(sanitizedRequest: Data, responseBytes: Data) {
    pairs.append((sanitizedRequest, responseBytes))
  }

  func flush(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      try? FileManager.default.removeItem(at: file)
    }
    for (index, pair) in pairs.enumerated() {
      let reqFile = directory.appendingPathComponent("\(index + 1).request.json")
      let sseFile = directory.appendingPathComponent("\(index + 1).output.sse")
      try pair.sanitizedRequest.write(to: reqFile)
      try pair.responseBytes.write(to: sseFile)
    }
  }
}

// MARK: - Record

private func recordRequest(
  request: Request,
  realClient: FetchClient,
  collector: RecordingCollector,
) async throws -> Response {
  let requestBodyData: Data
  if let body = request.body {
    requestBodyData = try await body.data()
  } else {
    requestBodyData = Data()
  }

  let reqData = serializeRequestForRecording(
    url: request.url,
    method: request.method,
    headers: redactedHeaders(request.headers),
    bodyData: requestBodyData,
  )

  let freshRequest = Request(
    url: request.url,
    method: request.method,
    headers: request.headers,
    body: requestBodyData.isEmpty
      ? nil
      : .bytes(requestBodyData, contentType: request.body?.contentType),
  )

  let response = try await realClient.fetch(freshRequest)
  guard (200 ..< 300).contains(response.status.code) else {
    let bodyText = (try? await response.body.text(upTo: 4096)) ?? "<no body>"
    throw RecordReplayError.unexpectedStatus(response.status.code, bodyText)
  }
  let bodyBytes = try await response.body.bytes()

  await collector.append(sanitizedRequest: reqData, responseBytes: Data(bodyBytes))

  return Response(
    status: response.status,
    headers: response.headers,
    body: .bytes(bodyBytes, contentType: response.body.contentType),
  )
}

// MARK: - Replay

private func replayResponse(request: Request, ledger: ReplayLedger, recordDir: URL) async throws -> Response {
  let currentBodyData: Data
  if let body = request.body {
    currentBodyData = try await body.data()
  } else {
    currentBodyData = Data()
  }
  let index = try await ledger.claim(decodeRequestBody(currentBodyData))
  let sseFile = recordDir.appendingPathComponent("\(index).output.sse")
  guard FileManager.default.fileExists(atPath: sseFile.path) else {
    throw RecordReplayError.noRecordingsFound(recordDir.lastPathComponent)
  }
  let sseBytes = try Data(contentsOf: sseFile)
  return Response(
    status: .ok,
    headers: HTTPFields(),
    body: .bytes(sseBytes, contentType: "text/event-stream"),
  )
}

// MARK: - Redaction

private let hmacSecret = SymmetricKey(data: Data("jiuziai-recording-hmac-secret-v1".utf8))

// Replay never compares headers; the HMAC is a non-leaking, key-stable
// fingerprint for humans inspecting fixtures.
private func redactedHeaders(_ headers: RequestHeaders) -> [String: String] {
  var dict: [String: String] = [:]
  for field in headers.fields {
    dict[field.name.rawName] = field.value
  }
  for (name, value) in headers.sensitiveValues {
    let signature = HMAC<SHA256>.authenticationCode(for: Data("\(name):\(value)".utf8), using: hmacSecret)
    dict[name] = "HMAC:SHA256:" + signature.map { String(format: "%02x", $0) }.joined()
  }
  return dict
}

// MARK: - Serialization

private struct RecordedRequest: Codable, Equatable {
  var url: String
  var method: String
  var headers: [String: String]
  var body: JSONValue
}

private let recordingJSONEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  return encoder
}()

private func decodeRequestBody(_ bodyData: Data) -> JSONValue {
  guard !bodyData.isEmpty else { return .null }
  if let body = try? JSONDecoder().decode(JSONValue.self, from: bodyData) {
    return body
  }
  return .string("non-JSON body of \(bodyData.count) bytes")
}

private func serializeRequestForRecording(
  url: URL,
  method: HTTPRequest.Method,
  headers: [String: String],
  bodyData: Data,
) -> Data {
  let request = RecordedRequest(
    url: url.absoluteString,
    method: method.rawValue,
    headers: headers,
    body: decodeRequestBody(bodyData),
  )
  return try! recordingJSONEncoder.encode(request)
}
