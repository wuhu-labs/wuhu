#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import enum PinnedTLS.PinnedTLS
import enum PinnedTLS.TrustPolicy
import Scratch
import Serve
import ServeNIO
import ServeTLS
import Testing

@Suite struct ServerTrustStoreTests {
  @Test func locatesTheUserStoreFromTheEnvironment() throws {
    let scratch = try ScratchFolder("trust")
    defer { scratch.remove() }
    let home = scratch.url.appendingPathComponent("home")
    let override = scratch.url.appendingPathComponent("override")
    #expect(try ServerTrust(environment: ["HOME": home.path]).directory.path == home.appendingPathComponent(".wuhu").path)
    #expect(try ServerTrust(environment: ["HOME": home.path, "WUHU_CONFIG_DIR": override.path]).directory.path == override.path)
  }

  @Test func emptyOrMissingLocationsFailLoudly() throws {
    let scratch = try ScratchFolder("trust")
    defer { scratch.remove() }
    let home = scratch.url.appendingPathComponent("home")
    #expect(throws: (any Error).self) {
      try ServerTrust(environment: ["HOME": home.path, "WUHU_CONFIG_DIR": ""])
    }
    #expect(throws: (any Error).self) {
      try ServerTrust(environment: ["HOME": ""])
    }
    #expect(throws: (any Error).self) {
      try ServerTrust(environment: [:])
    }
  }

  @Test func recordsReadsAndRemovesFingerprintsPerHost() throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try ServerTrust(environment: ["WUHU_CONFIG_DIR": directory.path])

    #expect(try trust.pin(forHost: "a.test:5540") == nil)
    try trust.record(hexFingerprint("a"), forHost: "a.test:5540")
    try trust.record(hexFingerprint("b"), forHost: "b.test:5540")
    #expect(try trust.pin(forHost: "a.test:5540") == hexFingerprint("a"))
    #expect(try trust.pin(forHost: "b.test:5540") == hexFingerprint("b"))

    try trust.record(hexFingerprint("c"), forHost: "a.test:5540")
    #expect(try trust.pin(forHost: "a.test:5540") == hexFingerprint("c"))

    try trust.removePin(forHost: "a.test:5540")
    #expect(try trust.pin(forHost: "a.test:5540") == nil)
    #expect(try trust.pin(forHost: "b.test:5540") == hexFingerprint("b"))

    try trust.removePin(forHost: "absent.test:5540")
    #expect(try trust.pin(forHost: "b.test:5540") == hexFingerprint("b"))
  }

  @Test(arguments: [
    "Y2VydC1h",
    "sha256:" + String(repeating: "A", count: 64),
    "sha256:" + String(repeating: "a", count: 63),
    "sha256:" + String(repeating: "a", count: 64) + "z",
    "sha256:" + String(repeating: "g", count: 64),
  ])
  func nonFingerprintValuesFailLoudlyOnLoad(value: String) throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"a.test:5540": "\#(value)"}"#.write(
      to: directory.appendingPathComponent("trust.json"), atomically: true, encoding: .utf8,
    )
    let trust = ServerTrust(directory: directory)
    #expect(throws: MalformedTrustStore.self) {
      try trust.pin(forHost: "a.test:5540")
    }
    #expect(throws: MalformedTrustStore.self) {
      try trust.pin(forHost: "unrelated.test:5540")
    }
  }

  @Test func machineHomeHonorsTheUserConfigOverride() throws {
    let scratch = try ScratchFolder("trust")
    defer { scratch.remove() }
    let override = scratch.url.appendingPathComponent("override")
    let home = try MachineHome.locate(environment: ["WUHU_CONFIG_DIR": override.path])
    #expect(home.directory.path == override.appendingPathComponent("machine").path)
    #expect(throws: (any Error).self) {
      try MachineHome.locate(environment: ["HOME": ""])
    }
  }

  @Test func hostKeyDefaultsTo443() throws {
    #expect(ServerTrust.hostKey(url: URL(string: "https://wuhu.test:5540/x")!) == "wuhu.test:5540")
    #expect(ServerTrust.hostKey(url: URL(string: "wss://wuhu.test/v1/exec")!) == "wuhu.test:443")
    #expect(ServerTrust.hostKey(url: URL(string: "https:///nohost")!) == nil)
  }

  @Test func policyIsPinXORSystem() throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)
    let url = URL(string: "https://wuhu.test:5540/x")!

    #expect(try SpaceTransport.policy(url: url, trust: trust) == .system)
    #expect(try SpaceTransport.policy(url: URL(string: "http://wuhu.test:5540/x")!, trust: trust) == nil)

    let fingerprint = PinnedTLS.fingerprint(certificateDER: [1, 2, 3])
    try trust.record(fingerprint, forHost: "wuhu.test:5540")
    #expect(try SpaceTransport.policy(url: url, trust: trust) == .pinned(fingerprint: fingerprint))
  }
}

@Suite(.serialized) struct SpaceTransportTests {
  @Test func unpinnedSecureTrafficStaysOnThePlainClientAndRecordsNothing() async throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)

    let url = URL(string: "https://127.0.0.1:5540/v1/server")!
    let client = SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: FetchClient { _ in
      Response(status: .ok, body: .chunk(Data("plain".utf8)))
    })
    let response = try await client(Request(url: url))
    #expect(try await response.body.text() == "plain")
    #expect(try trust.pin(forHost: "127.0.0.1:5540") == nil)
  }

  @Test func recordedPinDrivesThePinnedDialAndMismatchHardFails() async throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)

    let first = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let second = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])

    try await withTLSEcho(identity: first) { port in
      let url = URL(string: "https://127.0.0.1:\(port)/v1/server")!
      let key = try #require(ServerTrust.hostKey(url: url))
      try trust.record(try first.fingerprint(), forHost: key)

      let response = try await pinnedOnlyClient(trust: trust)(Request(url: url))
      #expect(response.status == .ok)
      #expect(try await response.body.text() == "{}")
    }

    // A host:port pinned to `first` now serves `second`: hard failure, named.
    // (Seeded pin instead of a same-port rebind, which races on Linux.)
    try await withTLSEcho(identity: second) { port in
      let url = URL(string: "https://127.0.0.1:\(port)/v1/server")!
      let key = try #require(ServerTrust.hostKey(url: url))
      try trust.record(try first.fingerprint(), forHost: key)

      let mismatch: PinMismatch
      do {
        _ = try await pinnedOnlyClient(trust: trust)(Request(url: url))
        Issue.record("expected the pinned dial to fail")
        return
      } catch {
        mismatch = try #require(await SpaceTransport.diagnosed(error, url: url, trust: trust) as? PinMismatch)
      }
      #expect(mismatch.host == "127.0.0.1:\(port)")
      #expect(mismatch.pinnedFingerprint == (try first.fingerprint()))
      #expect(mismatch.observedFingerprint == (try second.fingerprint()))
      #expect(mismatch.description.contains("wuhu trust 127.0.0.1:\(port)"))

      // Re-record the served certificate (what wuhu trust does) and the pinned
      // dial recovers.
      let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
      try trust.record(try PinnedTLS.fingerprint(certificateDERBase64: observed), forHost: key)
      let response = try await pinnedOnlyClient(trust: trust)(Request(url: url))
      #expect(response.status == .ok)
    }
  }

  @Test func pinnedFetchSucceedsAgainstACASignedChain() async throws {
    let directory = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = ServerTrust(directory: directory)

    let authority = try TLSIdentity.selfSigned(hosts: ["wuhu-test-ca"])
    let identity = try TLSIdentity.issued(hosts: ["localhost", "127.0.0.1"], by: authority)

    try await withTLSEcho(identity: identity) { port in
      let url = URL(string: "https://127.0.0.1:\(port)/v1/server")!
      let key = try #require(ServerTrust.hostKey(url: url))
      try trust.record(try identity.fingerprint(), forHost: key)

      let response = try await pinnedOnlyClient(trust: trust)(Request(url: url))
      #expect(response.status == .ok)
      #expect(try await response.body.text() == "{}")
    }
  }

  @Test func pinRecordedInOneFolderIsHonoredFromEveryOther() async throws {
    let root = try scratchURL("trust")
    defer { try? FileManager.default.removeItem(at: root) }
    let userDir = root.appendingPathComponent("user-config", isDirectory: true)
    let folderA = root.appendingPathComponent("a", isDirectory: true)
    let folderB = root.appendingPathComponent("b", isDirectory: true)
    for folder in [folderA, folderB] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let environment = [
      "HOME": root.appendingPathComponent("home").path,
      "WUHU_CONFIG_DIR": userDir.path,
    ]

    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withTLSEcho(identity: identity, body: #"{"token":"t1","content":"hi"}"#) { port in
      let host = "127.0.0.1:\(port)"
      let trust = try ServerTrust(environment: environment)
      let cliA = CLI(environment: environment, currentDirectory: folderA.path, trust: trust)
      let pinCode = await withDependencies {
        $0[ServerTrustProbe.self] = ServerTrustProbe(
          validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
          observeLeaf: { host, port in try await PinnedTLS.probeCertificate(host: host, port: port) },
        )
      } operation: {
        await cliA.runner.run(arguments: ["use", "--pin", host])
      }
      #expect(pinCode == 0)
      #expect((await cliA.stdout.text).contains("pinned server certificate \(try identity.fingerprint())"))
      #expect(!FileManager.default.fileExists(atPath: folderA.appendingPathComponent(".wuhu/trust.json").path))
      #expect(try trust.pin(forHost: host) == (try identity.fingerprint()))

      // Folder B honors the pin without re-pinning: use skips system
      // validation, and the actual dial verifies the pinned certificate.
      let cliB = CLI(environment: environment, currentDirectory: folderB.path, trust: trust)
      let useCode = await withDependencies {
        $0[ServerTrustProbe.self] = ServerTrustProbe(
          validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
          observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
        )
      } operation: {
        await cliB.runner.run(arguments: ["use", host])
      }
      #expect(useCode == 0)
      #expect((await cliB.stdout.text).contains("(pinned)"))
      #expect(await cliB.runner.run(arguments: ["read", "/a"]) == 0)
      #expect((await cliB.stdout.text).contains("hi"))

      #expect(await cliB.runner.run(arguments: ["untrust", host]) == 0)
      #expect((await cliB.stdout.text).contains("forgot \(host)"))
      let forgotten = try trust.pin(forHost: host)
      #expect(forgotten == nil)
      #expect(await cliB.runner.run(arguments: ["untrust", host]) == 0)
      #expect((await cliB.stdout.text).contains("no trust record for \(host)"))

      // Without the pin the next use falls back to system trust, which
      // rejects the self-signed certificate and offers --pin.
      let rejected = await withDependencies {
        $0[ServerTrustProbe.self] = ServerTrustProbe(
          validateSystem: { _, _ in throw CLIError(message: "certificate not trusted") },
          observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
        )
      } operation: {
        await cliB.runner.run(arguments: ["use", host])
      }
      #expect(rejected != 0)
      #expect((await cliB.stderr.text).contains("wuhu use \(host) --pin"))
    }
  }
}

private func hexFingerprint(_ character: Character) -> String {
  "sha256:" + String(repeating: character, count: 64)
}

private actor TextSink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}

private struct CLI {
  let runner: CommandRunner
  let stdout: TextSink
  let stderr: TextSink

  init(environment: [String: String], currentDirectory: String, trust: ServerTrust? = nil) {
    let stdout = TextSink()
    let stderr = TextSink()
    self.stdout = stdout
    self.stderr = stderr
    let plain = FetchClient { request in
      Issue.record("pinned host must not reach the plain client: \(request.url)")
      throw FetchError.unimplemented
    }
    self.runner = CommandRunner(
      fetch: trust.map { SpaceTransport.fetchClient(trust: $0, timeout: .seconds(10), plain: plain) } ?? plain,
      stdin: { "" },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: environment,
      currentDirectory: currentDirectory,
    )
  }
}

private func pinnedOnlyClient(trust: ServerTrust) -> FetchClient {
  SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: FetchClient { request in
    Issue.record("pinned host must not reach the plain client: \(request.url)")
    throw FetchError.unimplemented
  })
}

private func withTLSEcho<T>(
  identity: TLSIdentity,
  body: String = "{}",
  _ operation: (Int) async throws -> T,
) async throws -> T {
  let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity) { _ in
    Response(status: .ok, body: .chunk(Data(body.utf8)))
  }
  do {
    let value = try await operation(try #require(server.boundAddress.port))
    await server.shutdown()
    return value
  } catch {
    await server.shutdown()
    throw error
  }
}
