import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct SSEMessage: Sendable, Hashable {
  public var event: String?
  public var data: String

  public init(event: String? = nil, data: String) {
    self.event = event
    self.data = data
  }
}

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
  func sse(for request: URLRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>
}

public struct URLSessionHTTPClient: HTTPClient {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw PiAIError.invalidResponse }
    return (data, http)
  }

  public func sse(for request: URLRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    #if os(Linux)
      // FoundationNetworking on Linux doesn’t currently support `URLSession.bytes(for:)`.
      // We fall back to reading the full response body, then parsing SSE frames.
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw PiAIError.invalidResponse }
      if http.statusCode < 200 || http.statusCode >= 300 {
        let body = String(decoding: data, as: UTF8.self)
        throw PiAIError.httpStatus(code: http.statusCode, body: body)
      }
      return SSEDecoder.decode(data)
    #else
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw PiAIError.invalidResponse }
      if http.statusCode < 200 || http.statusCode >= 300 {
        let body = try? await readBody(bytes: bytes, limitBytes: 64 * 1024)
        throw PiAIError.httpStatus(code: http.statusCode, body: body)
      }
      return SSEDecoder.decode(bytes)
    #endif
  }
}

public enum SSEDecoder {
  public static func decode(_ data: Data) -> AsyncThrowingStream<SSEMessage, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var buffer = data
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

        if !buffer.isEmpty {
          yieldChunk(buffer, continuation: continuation)
        }
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  #if !os(Linux)
    public static func decode(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEMessage, any Error> {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            var buffer = Data()
            buffer.reserveCapacity(8 * 1024)

            for try await byte in bytes {
              buffer.append(byte)

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

            if !buffer.isEmpty {
              yieldChunk(buffer, continuation: continuation)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: PiAIError.decoding(String(describing: error)))
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }
  #endif

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

#if !os(Linux)
  private func readBody(bytes: URLSession.AsyncBytes, limitBytes: Int) async throws -> String {
    var data = Data()
    data.reserveCapacity(min(4 * 1024, limitBytes))
    var count = 0
    for try await byte in bytes {
      if count >= limitBytes { break }
      data.append(byte)
      count += 1
    }
    return String(decoding: data, as: UTF8.self)
  }
#endif
