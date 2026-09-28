#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Fetch
import enum PinnedTLS.PinnedTLS
import Scratch
import Serve
import ServeNIO
import ServeTLS
import struct SpaceClient.SpaceClient
import Testing

@Suite(.serialized) struct TrustDialPathsTests {
  enum Chain: CaseIterable {
    case selfSigned
    case caSigned

    func identity() throws -> TLSIdentity {
      switch self {
      case .selfSigned:
        try .selfSigned(hosts: ["localhost", "127.0.0.1"])
      case .caSigned:
        try .issued(hosts: ["localhost", "127.0.0.1"], by: .selfSigned(hosts: ["wuhu-test-ca"]))
      }
    }
  }

  @Test(arguments: Chain.allCases)
  func matchingPinSucceedsAcrossHTTPSSEAndWebSocket(chain: Chain) async throws {
    let directory = try scratchURL("trust-dial")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)
    let identity = try chain.identity()

    try await withDialServer(identity: identity) { port in
      try trust.record(try identity.fingerprint(), forHost: "127.0.0.1:\(port)")
      let fetch = SpaceTransport.diagnosing(pinnedOnlyClient(trust: trust), trust: trust)
      let client = SpaceClient(space: "https://127.0.0.1:\(port)", fetch: fetch, observeFetch: fetch)

      let read: ReadProbe = try await client.tool("read", ["path": "/x"])
      #expect(read.content == "hello")

      var events = try await client.sse("/v1/observe").makeAsyncIterator()
      #expect(try await events.next()?.data == "observed")

      let dial = SpaceTransport.webSocketTransport(trust: trust, maxFrameBytes: 1 << 20)
      let transport = try await dial(URL(string: "wss://127.0.0.1:\(port)/ws")!, [])
      try await transport.send([1, 2, 3])
      var frames = transport.inbound.makeAsyncIterator()
      #expect(await frames.next() == [1, 2, 3])
      transport.close()
    }
  }

  @Test func dataVerbAgainstAnUntrustedServerSurfacesThePinHint() async throws {
    let root = try scratchURL("trust-dial")
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let trust = ServerTrust(directory: root.appendingPathComponent("user-config", isDirectory: true))

    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withDialServer(identity: identity) { port in
      struct HandshakeFailure: Error {}
      let plain = FetchClient { _ in throw HandshakeFailure() }
      let stderr = TextSink()
      let runner = CommandRunner(
        fetch: SpaceTransport.diagnosing(
          SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: plain),
          trust: trust,
        ),
        stdin: { "" },
        stdout: { _ in },
        stderr: { text in await stderr.append(text) },
        environment: [
          "HOME": root.appendingPathComponent("home").path,
          "WUHU_CONFIG_DIR": trust.directory.path,
        ],
        currentDirectory: work.path,
      )
      let code = await runner.run(arguments: ["read", "wuhu://127.0.0.1:\(port)/x"])
      #expect(code == 1)
      let error = await stderr.text
      #expect(error.contains("127.0.0.1:\(port) presented a certificate this system does not trust"))
      #expect(error.contains("wuhu use 127.0.0.1:\(port) --pin"))
    }
  }

  @Test func dataVerbWithAMalformedTrustStoreSurfacesTheStoreErrorNotThePinHint() async throws {
    let root = try scratchURL("trust-dial")
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    let configDir = root.appendingPathComponent("user-config", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try #"{"127.0.0.1:5640": "garbage"}"#.write(
      to: configDir.appendingPathComponent("trust.json"), atomically: true, encoding: .utf8,
    )
    let trust = ServerTrust(directory: configDir)

    let stderr = TextSink()
    let runner = CommandRunner(
      fetch: SpaceTransport.diagnosing(pinnedOnlyClient(trust: trust), trust: trust),
      stdin: { "" },
      stdout: { _ in },
      stderr: { text in await stderr.append(text) },
      environment: [
        "HOME": root.appendingPathComponent("home").path,
        "WUHU_CONFIG_DIR": configDir.path,
      ],
      currentDirectory: work.path,
    )
    let code = await runner.run(arguments: ["read", "wuhu://127.0.0.1:5640/x"])
    #expect(code == 1)
    let error = await stderr.text
    #expect(error.contains("malformed trust store"))
    #expect(error.contains("fix or remove it"))
    #expect(!error.contains("presented a certificate this system does not trust"))
  }

  @Test func webSocketDialAgainstAChangedPinNamesBothFingerprints() async throws {
    let directory = try scratchURL("trust-dial")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)

    let served = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let pinned = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withDialServer(identity: served) { port in
      try trust.record(try pinned.fingerprint(), forHost: "127.0.0.1:\(port)")
      let dial = SpaceTransport.webSocketTransport(trust: trust, maxFrameBytes: 1 << 20)
      do {
        _ = try await dial(URL(string: "wss://127.0.0.1:\(port)/ws")!, [])
        Issue.record("expected the mismatched dial to fail")
      } catch let mismatch as PinMismatch {
        #expect(mismatch.pinnedFingerprint == (try pinned.fingerprint()))
        #expect(mismatch.observedFingerprint == (try served.fingerprint()))
      }
    }
  }
}

private struct ReadProbe: Decodable {
  let content: String
}

private actor TextSink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}

private func pinnedOnlyClient(trust: ServerTrust) -> FetchClient {
  SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: FetchClient { request in
    Issue.record("pinned host must not reach the plain client: \(request.url)")
    throw FetchError.unimplemented
  })
}

private func withDialServer(identity: TLSIdentity, _ operation: (Int) async throws -> Void) async throws {
  let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: { request in
    if Serve.isWebSocketUpgradeRequest(request) {
      return .webSocket { socket in
        for await message in socket.inbound {
          try? await socket.send(message)
        }
        socket.close()
      }
    }
    if request.url.path == "/v1/observe" {
      return .response(Response(status: .ok, body: .chunk(Data("data: observed\n\n".utf8), contentType: "text/event-stream")))
    }
    return .response(Response(status: .ok, body: .chunk(Data(#"{"content":"hello","token":"t1"}"#.utf8), contentType: "application/json")))
  })
  do {
    try await operation(try #require(server.boundAddress.port))
    await server.shutdown()
  } catch {
    await server.shutdown()
    throw error
  }
}
