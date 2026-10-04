#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
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

  public struct ToolFailure: Error {
    public let error: ToolError
  }

  public struct TransportFailure: Error {
    public let message: String
    public let status: Int?
    public let code: String?

    init(message: String, status: Int? = nil, code: String? = nil) {
      self.message = message
      self.status = status
      self.code = code
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

  public func fileBytes(_ path: String) async throws -> Data {
    let response = try await self.fetch(Request(url: try self.fileURL(path)))
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    return try await response.data()
  }

  public func putFileBytes<Output: Decodable>(_ path: String, _ data: Data, ifMatch: String?) async throws -> Output {
    var request = Request(url: try self.fileURL(path), method: .put, body: .bytes(data, contentType: "application/octet-stream"))
    if let ifMatch {
      request.headers["if-match"] = "\"\(ifMatch)\""
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

  private func fileURL(_ path: String) throws -> URL {
    guard var components = URLComponents(string: self.base) else {
      throw InvalidSpace(space: self.base)
    }
    if let qualified = try GroupID.address(path) {
      components.path = "/v1/f" + qualified.path
      components.queryItems = [URLQueryItem(name: "group", value: qualified.group.rawValue)]
    } else {
      components.path = "/v1/f" + path
    }
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

  static func failure(from response: Response) async -> any Error {
    let text = (try? await response.text()) ?? ""
    if let value = JSONValue.parse(text),
       let error = try? JSONValueDecoder().decode(ToolError.self, from: value)
    {
      return ToolFailure(error: error)
    }
    return TransportFailure(message: "HTTP \(response.status.code): \(text)", status: response.status.code, code: JSONValue.parse(text)?.object?["code"]?.stringValue)
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
