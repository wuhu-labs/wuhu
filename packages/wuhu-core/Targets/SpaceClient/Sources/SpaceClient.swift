#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import JSONValue
import protocol MachineChannel.FrameTransport
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupID
import struct SpaceContract.ToolError
import struct SpaceContract.TranscriberInfo
import struct SpaceContract.TranscriptionOutput

public struct SpaceClient: Sendable {
  public let base: String
  let fetch: FetchClient
  let observeFetch: FetchClient
  let dial: @Sendable (URL, [(String, String)]) async throws -> any FrameTransport

  /// A nil `group` sends no `Wuhu-Group` header at all, so the server picks the group.
  public init(
    space: String,
    fetch: FetchClient,
    observeFetch: FetchClient? = nil,
    dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)? = nil,
    group: String? = nil,
  ) {
    self.base = normalizeBase(space)
    let dial = dial ?? { _, _ in
      throw TransportFailure(message: "no websocket transport is available in this client")
    }
    guard let group else {
      self.fetch = fetch
      self.observeFetch = observeFetch ?? fetch
      self.dial = dial
      return
    }
    self.fetch = fetch.acting(in: group)
    self.observeFetch = (observeFetch ?? fetch).acting(in: group)
    self.dial = { url, headers in try await dial(url, headers + [(GroupHeader.name, group)]) }
  }

  public struct ToolFailure: Error, CustomStringConvertible {
    public let error: ToolError
    public var description: String { error.message }
  }

  public struct TransportFailure: Error, CustomStringConvertible {
    public let message: String
    public let status: Int?
    public let code: String?
    public var description: String { message }

    init(message: String, status: Int? = nil, code: String? = nil) {
      self.message = message
      self.status = status
      self.code = code
    }
  }

  /// A WebSocket dial the server answered with a plain HTTP response instead
  /// of an upgrade. The message is the server's `{code, message}` error body
  /// when it sent one, else the body's text.
  public struct DialRefusal: Error, Equatable, CustomStringConvertible {
    public let status: Int
    public let code: String?
    public let message: String

    public init(status: Int, body: [UInt8]) {
      self.status = status
      let text = String(decoding: body, as: UTF8.self)
      let object = JSONValue.parse(text)?.object
      self.code = object?["code"]?.stringValue
      self.message = object?["message"]?.stringValue ?? String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }

    /// A client error is the server's answer, and dialing again gets the
    /// same one; only a timeout or rate limit is worth another try.
    public var isFinal: Bool {
      (400 ..< 500).contains(self.status) && self.status != 408 && self.status != 429
    }

    public var description: String {
      let head = [String(self.status), self.code].compactMap(\.self).joined(separator: " ")
      return self.message.isEmpty ? head : "\(head): \(self.message)"
    }
  }

  public struct InvalidSpace: Error {
    public let space: String
  }

  public func tool<Output: Decodable>(_ name: String, _ input: JSONValue) async throws -> Output {
    var request = Request(url: try self.url("/v1/tools/\(name)"), method: .post)
    request.body = .bytes(Data(input.jsonString().utf8), contentType: "application/json")
    return try await self.send(request, via: self.fetch)
  }

  public func api<Output: Decodable>(
    _ method: Fetch.Method,
    _ path: String,
    body: JSONValue? = nil,
  ) async throws -> Output {
    var request = Request(url: try self.url(path), method: method)
    if let body {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    return try await self.send(request, via: self.fetch)
  }

  public func api<Output: Decodable>(
    _ method: Fetch.Method,
    _ path: String,
    form: MultipartForm,
  ) async throws -> Output {
    var request = Request(url: try self.url(path), method: method)
    request.body = form.finish()
    return try await self.send(request, via: self.fetch)
  }

  /// One `GET /v1/f/*` answer: the bytes with the version they were read at.
  public struct FileRead: Sendable {
    public let token: String
    public let rev: Int?
    public let data: Data
  }

  /// `rev` reads the file as of that revision; `limit` has the server refuse a
  /// larger file before any byte moves.
  public func file(_ path: String, rev: Int? = nil, limit: Int? = nil) async throws -> FileRead {
    var query: [URLQueryItem] = []
    if let rev { query.append(URLQueryItem(name: "rev", value: String(rev))) }
    if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
    let response = try await self.fetch(Request(url: try self.fileURL(path, query: query)))
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    let etag = response.headers[.eTag] ?? ""
    let token = etag.count >= 2 && etag.hasPrefix("\"") && etag.hasSuffix("\"") ? String(etag.dropFirst().dropLast()) : etag
    return FileRead(token: token, rev: response.headers[HTTPField.Name("wuhu-rev")!].flatMap(Int.init), data: try await response.data())
  }

  public func fileBytes(_ path: String) async throws -> Data {
    try await self.file(path).data
  }

  /// `createOnly` has the server refuse a path that already has a file (`If-None-Match: *`).
  public func putFileBytes<Output: Decodable>(_ path: String, _ data: Data, ifMatch: String?, createOnly: Bool = false) async throws -> Output {
    var request = Request(url: try self.fileURL(path), method: .put, body: .bytes(data, contentType: "application/octet-stream"))
    if let ifMatch {
      request.headers["if-match"] = "\"\(ifMatch)\""
    }
    if createOnly {
      request.headers["if-none-match"] = "*"
    }
    return try await self.send(request, via: self.fetch)
  }

  public func transcribe(_ audio: Data, contentType: String, language: String? = nil, provider: String? = nil, model: String? = nil, timestamps: String? = nil, diarize: Bool? = nil) async throws -> TranscriptionOutput {
    guard var components = URLComponents(string: self.base + "/v1/transcribe") else {
      throw InvalidSpace(space: self.base)
    }
    components.queryItems = [("language", language), ("provider", provider), ("model", model), ("timestamps", timestamps), ("diarize", diarize.map(String.init))]
      .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    guard let url = components.url else { throw InvalidSpace(space: self.base) }
    var request = Request(url: url, method: .post, body: .bytes(audio, contentType: contentType))
    request.headers["content-type"] = contentType
    return try await self.send(request, via: self.fetch)
  }

  public func transcriber() async throws -> TranscriberInfo {
    try await self.api(.get, "/v1/transcribe")
  }

  private func fileURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
    guard var components = URLComponents(string: self.base) else {
      throw InvalidSpace(space: self.base)
    }
    var items = query
    if let qualified = try GroupID.address(path) {
      components.path = "/v1/f" + qualified.path
      items.append(URLQueryItem(name: "group", value: qualified.group.rawValue))
    } else if path.hasPrefix("machines://") {
      let rest = path.dropFirst("machines://".count)
      let slash = rest.firstIndex(of: "/") ?? rest.endIndex
      components.path = "/v1/f" + (slash == rest.endIndex ? "/" : String(rest[slash...]))
      items.append(URLQueryItem(name: "machine", value: String(rest[..<slash])))
    } else {
      components.path = "/v1/f" + path
    }
    if !items.isEmpty { components.queryItems = items }
    guard let url = components.url else { throw InvalidSpace(space: self.base) }
    return url
  }

  func url(_ path: String) throws -> URL {
    guard let url = URL(string: self.base + path) else {
      throw InvalidSpace(space: self.base)
    }
    return url
  }

  private func send<Output: Decodable>(_ request: Request, via client: FetchClient) async throws -> Output {
    let response = try await client(request)
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    let text = try await response.text()
    guard let value = JSONValue.parse(text) else {
      throw TransportFailure(message: "HTTP \(response.status.code): invalid JSON response")
    }
    return try JSONValueDecoder().decode(Output.self, from: value)
  }

  // A tool-shaped `{code, message, hint?, token?}` body is a ToolFailure; a
  // route's own `{code, message}` (a code no tool uses) keeps the server's
  // message and code; anything else is the raw status and text.
  static func failure(from response: Response) async -> any Error {
    let text = (try? await response.text()) ?? ""
    let body = JSONValue.parse(text)
    if let body, let error = try? JSONValueDecoder().decode(ToolError.self, from: body) {
      return ToolFailure(error: error)
    }
    if let code = body?.object?["code"]?.stringValue, let message = body?.object?["message"]?.stringValue {
      return TransportFailure(message: message, status: response.status.code, code: code)
    }
    return TransportFailure(message: "HTTP \(response.status.code): \(text)", status: response.status.code, code: nil)
  }
}

private extension FetchClient {
  func acting(in group: String) -> FetchClient {
    FetchClient { request in
      var request = request
      request.headers[GroupHeader.name] = group
      return try await self(request)
    }
  }
}

func normalizeBase(_ space: String) -> String {
  let trimmed = space.trimmingSlashes()
  if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
    return trimmed
  }
  return "https://\(trimmed)"
}

private extension String {
  func trimmingSlashes() -> String {
    var start = self.startIndex
    var end = self.endIndex
    while start < end, self[start] == "/" {
      start = self.index(after: start)
    }
    while start < end, self[self.index(before: end)] == "/" {
      end = self.index(before: end)
    }
    return String(self[start ..< end])
  }
}
