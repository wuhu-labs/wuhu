import AsyncHTTPClient
import Foundation

public struct SSEMessage: Sendable, Hashable {
  public var event: String?
  public var data: String

  public init(event: String? = nil, data: String) {
    self.event = event
    self.data = data
  }
}

public struct HTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data?

  public init(
    url: URL,
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil,
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }

  public mutating func setHeader(_ value: String, for name: String) {
    headers[name] = value
  }
}

public struct HTTPResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: [String]]

  public init(statusCode: Int, headers: [String: [String]] = [:]) {
    self.statusCode = statusCode
    self.headers = headers
  }
}

public protocol HTTPClient: Sendable {
  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse)
  func sse(for request: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>
}

public final class AsyncHTTPClientTransport: HTTPClient, @unchecked Sendable {
  private let client: AsyncHTTPClient.HTTPClient
  private let requestTimeoutSeconds: Int64
  private let sseTimeoutSeconds: Int64
  private let ownsClient: Bool

  public convenience init(client: AsyncHTTPClient.HTTPClient? = nil, requestTimeoutSeconds: Int64 = 300) {
    self.init(client: client, requestTimeoutSeconds: requestTimeoutSeconds, sseTimeoutSeconds: 86400)
  }

  public init(
    client: AsyncHTTPClient.HTTPClient? = nil,
    requestTimeoutSeconds: Int64 = 300,
    sseTimeoutSeconds: Int64,
  ) {
    if let client {
      self.client = client
      ownsClient = false
    } else {
      self.client = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .singleton)
      ownsClient = true
    }
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.sseTimeoutSeconds = sseTimeoutSeconds
  }

  deinit {
    guard ownsClient else { return }
    try? client.syncShutdown()
  }

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    let response = try await execute(request, timeoutSeconds: requestTimeoutSeconds)
    let body = try await readBody(response.body, limitBytes: .max)
    return (body, makeResponseMetadata(response))
  }

  public func sse(for request: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    let response = try await execute(request, timeoutSeconds: sseTimeoutSeconds)
    let metadata = makeResponseMetadata(response)

    if metadata.statusCode < 200 || metadata.statusCode >= 300 {
      let body = try await readBody(response.body, limitBytes: 64 * 1024)
      throw PiAIError.httpStatus(code: metadata.statusCode, body: String(decoding: body, as: UTF8.self))
    }

    // Keep `self` alive for the lifetime of the stream. Callers often create a temporary transport/client
    // (e.g. `WuhuClient(baseURL:).followSessionStream(...)`) and only retain the returned stream. If the
    // transport is deinitialized, it will shut down the underlying AsyncHTTPClient and cancel the in-flight
    // SSE body stream, which surfaces as `HTTPClientError.cancelled`.
    let body = response.body
    return AsyncThrowingStream { continuation in
      let task = Task { [self] in
        _ = self
        do {
          for try await message in SSEDecoder.decode(body) {
            continuation.yield(message)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func execute(_ request: HTTPRequest, timeoutSeconds: Int64) async throws -> AsyncHTTPClient.HTTPClientResponse {
    var outgoing = AsyncHTTPClient.HTTPClientRequest(url: request.url.absoluteString)
    outgoing.method = .RAW(value: request.method.uppercased())

    for (name, value) in request.headers {
      outgoing.headers.add(name: name, value: value)
    }

    if let body = request.body {
      outgoing.body = .bytes(body)
    }

    return try await client.execute(outgoing, timeout: .seconds(timeoutSeconds))
  }

  private func makeResponseMetadata(_ response: AsyncHTTPClient.HTTPClientResponse) -> HTTPResponse {
    var headers: [String: [String]] = [:]
    for header in response.headers {
      headers[header.name, default: []].append(header.value)
    }
    return HTTPResponse(statusCode: Int(response.status.code), headers: headers)
  }

  private func readBody(_ body: AsyncHTTPClient.HTTPClientResponse.Body, limitBytes: Int) async throws -> Data {
    var data = Data()
    data.reserveCapacity(min(4 * 1024, limitBytes))
    var count = 0

    for try await var chunk in body {
      let readable = chunk.readableBytes
      if readable == 0 { continue }

      let remaining = limitBytes - count
      if remaining <= 0 { break }

      let toRead = min(readable, remaining)
      guard let bytes = chunk.readBytes(length: toRead) else { continue }
      data.append(contentsOf: bytes)
      count += bytes.count

      if toRead < readable {
        break
      }
    }

    return data
  }
}

public enum SSEDecoder {
  public static func decode(_ data: Data) -> AsyncThrowingStream<SSEMessage, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var buffer = data
        drain(buffer: &buffer, continuation: continuation)
        // If the data doesn't end with an SSE frame delimiter, treat any remaining bytes as a partial
        // frame and drop them.
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  static func decode(_ body: AsyncHTTPClient.HTTPClientResponse.Body) -> AsyncThrowingStream<SSEMessage, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var buffer = Data()
          buffer.reserveCapacity(8 * 1024)

          for try await var chunk in body {
            guard let bytes = chunk.readBytes(length: chunk.readableBytes), !bytes.isEmpty else { continue }
            buffer.append(contentsOf: bytes)
            drain(buffer: &buffer, continuation: continuation)
          }

          // If we reach EOF without an SSE frame delimiter, treat the remaining bytes as a partial frame
          // and drop them. This commonly happens when a client cancels a request mid-frame.
          continuation.finish()
        } catch {
          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private static func drain(
    buffer: inout Data,
    continuation: AsyncThrowingStream<SSEMessage, any Error>.Continuation,
  ) {
    while true {
      if let range = buffer.range(of: Data([13, 10, 13, 10])) { // \r\n\r\n
        let chunkData = buffer.subdata(in: 0 ..< range.lowerBound)
        buffer.removeSubrange(0 ..< range.upperBound)
        yieldChunk(chunkData, continuation: continuation)
        continue
      }
      if let range = buffer.range(of: Data([10, 10])) { // \n\n
        let chunkData = buffer.subdata(in: 0 ..< range.lowerBound)
        buffer.removeSubrange(0 ..< range.upperBound)
        yieldChunk(chunkData, continuation: continuation)
        continue
      }
      break
    }
  }

  private static func parseChunk(_ chunk: String) -> SSEMessage? {
    var event: String?
    var dataLines: [String] = []

    for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("event:") {
        event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        dataLines.append(data)
      }
    }

    let data = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !data.isEmpty, data != "[DONE]" else { return nil }
    return SSEMessage(event: event, data: data)
  }

  private static func yieldChunk(_ chunkData: Data, continuation: AsyncThrowingStream<SSEMessage, any Error>.Continuation) {
    if chunkData.isEmpty { return }
    var chunk = String(decoding: chunkData, as: UTF8.self)
    chunk = chunk.replacingOccurrences(of: "\r\n", with: "\n")
    if let message = parseChunk(chunk) {
      continuation.yield(message)
    }
  }
}
