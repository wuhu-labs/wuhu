#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import NIOCore
import NIOHTTP1
import NIOSSL
import Serve
import ServeNIO
import ServeTLS
import Synchronization
import Testing

@Suite(.serialized)
struct TLSNIOTests {
  @Test func alpnSelectsH2AndServesRequests() async throws {
    try await withTLSServer { request in
      Response(status: .ok, body: .chunk(Data("\(request.url.scheme ?? "?") \(request.url.path)".utf8)))
    } operation: { server, _ in
      try await withTLSClient(httpVersion: .automatic) { client in
        let response = try await client.execute(
          HTTPClientRequest(url: "https://127.0.0.1:\(try #require(server.boundAddress.port))/hello"),
          timeout: .seconds(10),
        )
        #expect(response.version == .http2)
        var body = try await response.body.collect(upTo: 1 << 16)
        #expect(body.readString(length: body.readableBytes) == "https /hello")
      }
    }
  }

  @Test func alpnFallsBackToHTTP1() async throws {
    try await withTLSServer { _ in
      Response(status: .ok, body: .chunk(Data("ok".utf8)))
    } operation: { server, _ in
      try await withTLSClient(httpVersion: .http1Only) { client in
        let response = try await client.execute(
          HTTPClientRequest(url: "https://127.0.0.1:\(try #require(server.boundAddress.port))/"),
          timeout: .seconds(10),
        )
        #expect(response.version == .http1_1)
        var body = try await response.body.collect(upTo: 1 << 16)
        #expect(body.readString(length: body.readableBytes) == "ok")
      }
    }
  }

  @Test func sseStreamsOverH2WithoutHTTP1Framing() async throws {
    let events = ["data: one\n\n", "data: two\n\n", "data: three\n\n"]
    try await withTLSServer { _ in
      Response(
        status: .ok,
        body: .chunks(events.map { Data($0.utf8) }, contentType: "text/event-stream; charset=utf-8"),
      )
    } operation: { server, _ in
      try await withTLSClient(httpVersion: .automatic) { client in
        let response = try await client.execute(
          HTTPClientRequest(url: "https://127.0.0.1:\(try #require(server.boundAddress.port))/v1/observe"),
          timeout: .seconds(10),
        )
        #expect(response.version == .http2)
        // AsyncHTTPClient synthesizes transfer-encoding on its h2-to-h1 surface;
        // connection absence is the assertable no-HTTP/1-framing signal.
        #expect(response.headers["connection"].isEmpty)
        var received = ""
        for try await var chunk in response.body {
          received += chunk.readString(length: chunk.readableBytes) ?? ""
        }
        #expect(received == events.joined())
      }
    }
  }

  @Test func twelveConcurrentStreamsShareOneConnection() async throws {
    try await withTLSServer { request in
      Response(
        status: .ok,
        body: .chunks([Data("data: \(request.url.path)\n\n".utf8)], contentType: "text/event-stream"),
      )
    } operation: { server, recorder in
      let port = try #require(server.boundAddress.port)
      try await withTLSClient(httpVersion: .automatic) { client in
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
          for index in 0 ..< 12 {
            group.addTask {
              let response = try await client.execute(
                HTTPClientRequest(url: "https://127.0.0.1:\(port)/stream/\(index)"),
                timeout: .seconds(10),
              )
              #expect(response.version == .http2)
              var body = try await response.body.collect(upTo: 1 << 16)
              return (index, body.readString(length: body.readableBytes) ?? "")
            }
          }
          var results: [Int: String] = [:]
          for try await (index, body) in group {
            results[index] = body
          }
          #expect(results.count == 12)
          for (index, body) in results {
            #expect(body == "data: /stream/\(index)\n\n")
          }
        }
      }
      #expect(recorder.snapshot().acceptedConnectionCount == 1)
    }
  }

  @Test func aPausedH2UploadResumesOnceTheHandlerDrainsIt() async throws {
    let options = ServeOptions(requestBodyHighWatermarkBytes: 4096, requestBodyLowWatermarkBytes: 1024)
    let chunk = ByteBuffer(repeating: 7, count: 32 << 10)
    let chunks = 32
    let (uploading, started) = AsyncStream.makeStream(of: Void.self)
    try await withTLSServer(options: options) { request in
      // Reading only once the client has sent past its first chunks lets the
      // stream buffer beyond the high watermark and pause.
      for await _ in uploading { break }
      var total = 0
      for try await piece in (request.body ?? .empty).asyncBytes() {
        total += piece.count
      }
      return Response(status: .ok, body: .chunk(Data("received \(total)".utf8)))
    } operation: { server, _ in
      try await withTLSClient(httpVersion: .automatic) { client in
        var request = HTTPClientRequest(url: "https://127.0.0.1:\(try #require(server.boundAddress.port))/upload")
        request.method = .POST
        let body = Upload(chunk: chunk, count: chunks, started: started)
        request.body = .stream(body, length: .known(Int64(chunk.readableBytes * chunks)))
        let response = try await client.execute(request, timeout: .seconds(10))
        #expect(response.version == .http2)
        var received = try await response.body.collect(upTo: 1 << 16)
        #expect(received.readString(length: received.readableBytes) == "received \(chunk.readableBytes * chunks)")
      }
    }
  }
}

private struct Upload: AsyncSequence, Sendable {
  let chunk: ByteBuffer
  let count: Int
  let started: AsyncStream<Void>.Continuation

  struct AsyncIterator: AsyncIteratorProtocol {
    let upload: Upload
    var index = 0

    mutating func next() async -> ByteBuffer? {
      guard index < upload.count else { return nil }
      if index == 3 { upload.started.yield() }
      index += 1
      return upload.chunk
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(upload: self)
  }
}

private func withTLSServer<T>(
  options: ServeOptions = .init(),
  handler: @escaping Handler,
  operation: (ServeNIOServer, TLSHookRecorder) async throws -> T,
) async throws -> T {
  let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
  let recorder = TLSHookRecorder()
  let server = try await ServeNIOServer.bind(
    host: "127.0.0.1",
    port: 0,
    tls: identity,
    options: options,
    hooks: recorder.hooks,
    handler: handler,
  )
  do {
    let value = try await operation(server, recorder)
    await server.shutdown()
    return value
  } catch {
    await server.shutdown()
    throw error
  }
}

private func withTLSClient(
  httpVersion: HTTPClient.Configuration.HTTPVersion,
  _ operation: (HTTPClient) async throws -> Void,
) async throws {
  var tls = TLSConfiguration.makeClientConfiguration()
  tls.certificateVerification = .none
  var configuration = HTTPClient.Configuration()
  configuration.tlsConfiguration = tls
  configuration.httpVersion = httpVersion
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  do {
    try await operation(client)
    try await client.shutdown()
  } catch {
    try? await client.shutdown()
    throw error
  }
}

private final class TLSHookRecorder: Sendable {
  struct Snapshot: Sendable {
    var acceptedConnectionCount = 0
  }

  private let storage = Mutex(Snapshot())

  var hooks: ServeNIOHooks {
    ServeNIOHooks(
      onDidAcceptConnection: { _ in
        self.storage.withLock { $0.acceptedConnectionCount += 1 }
      },
    )
  }

  func snapshot() -> Snapshot {
    self.storage.withLock { $0 }
  }
}
