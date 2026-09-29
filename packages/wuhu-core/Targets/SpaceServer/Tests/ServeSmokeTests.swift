import Fetch
import Foundation
import enum PinnedTLS.PinnedTLS
import Scratch
import ServeNIO
import ServeTLS
import SpaceServer
import Synchronization
import Testing

@Suite struct ServeSmokeTests {
  private func scratch() throws -> URL {
    let base = try scratchURL("serve-smoke")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  @Test func serveImportsRunsAndExportsAcrossGracefulShutdown() async throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    let importDir = base.appendingPathComponent("import")
    let exportDir = base.appendingPathComponent("export")
    let store = base.appendingPathComponent("store")
    try FileManager.default.createDirectory(
      at: importDir.appendingPathComponent("notes"), withIntermediateDirectories: true,
    )
    try "hello".write(to: importDir.appendingPathComponent("notes/a.md"), atomically: true, encoding: .utf8)

    let (binds, bindsContinuation) = AsyncStream<Void>.makeStream()
    let hooks = ServeNIOHooks(
      onDidBind: { _ in bindsContinuation.yield() },
      onStartupFailure: { _ in bindsContinuation.finish() },
    )
    let server = Task {
      try await SpaceServer.serve(
        folder: store, port: 0, webPort: 0, dev: true, devImport: importDir, devExport: exportDir, hooks: hooks,
      )
    }
    var iterator = binds.makeAsyncIterator()
    _ = await iterator.next()
    _ = await iterator.next()
    server.cancel()
    try await server.value

    let exported = exportDir.appendingPathComponent("notes/a.md")
    #expect(try String(contentsOf: exported, encoding: .utf8) == "hello")
  }

  @Test func webPortBindFailureTearsDownTheApiListener() async throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }

    let squatter = try await ServeNIOServer.bind(port: 0) { _ in Response(status: .ok) }
    let busyPort = try #require(squatter.localAddress?.port)

    let bound = Mutex<[Int?]>([])
    let torndown = Mutex<[Int?]>([])
    let hooks = ServeNIOHooks(
      onDidBind: { address in bound.withLock { $0.append(address.port) } },
      onDidShutdown: { address in torndown.withLock { $0.append(address.port) } },
    )
    await #expect(throws: (any Error).self) {
      try await SpaceServer.serve(
        folder: base.appendingPathComponent("store"), port: 0, webPort: busyPort, dev: true, hooks: hooks,
      )
    }

    let apiPort = try #require(bound.withLock { $0 }.first ?? nil)
    #expect(bound.withLock { $0 } == [apiPort])
    #expect(torndown.withLock { $0 } == [apiPort])
    await squatter.shutdown()
  }

  // The bare host keeps the exact leaf clients pinned; only `<g>.<host>`
  // names get the group leaf, on both listeners.
  @Test func groupHostsGetTheGroupLeafAndEveryOtherNameTheServersOwn() async throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    let authority = try TLSIdentity.selfSigned(hosts: ["wuhu-test-ca"])
    let own = try TLSIdentity.issued(hosts: ["space.test"], by: authority)
    let group = try TLSIdentity.issued(hosts: ["*.space.test"], by: authority)
    func pem(_ name: String, _ text: String) throws -> URL {
      let url = base.appendingPathComponent(name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    }
    let (binds, bindsContinuation) = AsyncStream<Int?>.makeStream()
    let hooks = ServeNIOHooks(
      onDidBind: { bindsContinuation.yield($0.port) },
      onStartupFailure: { _ in bindsContinuation.finish() },
    )
    let certificate = try pem("own.pem", own.certificatePEM)
    let privateKey = try pem("own.key", own.privateKeyPEM)
    let groupCertificate = try pem("group.pem", group.certificatePEM)
    let groupPrivateKey = try pem("group.key", group.privateKeyPEM)
    let server = Task {
      try await SpaceServer.serve(
        folder: base.appendingPathComponent("store"), port: 0, origin: URL(string: "https://space.test:5530"), webPort: 0,
        dev: true, certificate: certificate, privateKey: privateKey,
        groupCertificate: groupCertificate, groupPrivateKey: groupPrivateKey, hooks: hooks,
      )
    }
    var iterator = binds.makeAsyncIterator()
    let ports = [try #require(await iterator.next() ?? nil), try #require(await iterator.next() ?? nil)]
    func leaf(_ port: Int, _ serverName: String?) async throws -> String {
      try PinnedTLS.fingerprint(certificateDERBase64: try await PinnedTLS.probeCertificate(
        host: "127.0.0.1", port: port, serverName: serverName,
      ))
    }
    for port in ports {
      #expect(try await leaf(port, nil) == (try own.fingerprint()))
      #expect(try await leaf(port, "space.test") == (try own.fingerprint()))
      #expect(try await leaf(port, "alice.space.test") == (try group.fingerprint()))
      #expect(try await leaf(port, "a.b.space.test") == (try own.fingerprint()))
    }
    server.cancel()
    try await server.value
  }

  @Test func aGroupCertificateNoHandshakeCanUseStopsTheStart() async throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    let certificate = base.appendingPathComponent("group.pem")
    let privateKey = base.appendingPathComponent("group.key")
    try explicitCurveGroupCertificatePEM.write(to: certificate, atomically: true, encoding: .utf8)
    try explicitCurveGroupKeyPEM.write(to: privateKey, atomically: true, encoding: .utf8)
    let own = try TLSIdentity.selfSigned(hosts: ["space.test"])
    let ownCertificate = base.appendingPathComponent("own.pem")
    let ownPrivateKey = base.appendingPathComponent("own.key")
    try own.certificatePEM.write(to: ownCertificate, atomically: true, encoding: .utf8)
    try own.privateKeyPEM.write(to: ownPrivateKey, atomically: true, encoding: .utf8)
    let refusal = await #expect(throws: GroupTLSError.self) {
      try await SpaceServer.serve(
        folder: base.appendingPathComponent("store"), port: 0, origin: URL(string: "https://space.test:5530"), webPort: 0,
        dev: true, certificate: ownCertificate, privateKey: ownPrivateKey,
        groupCertificate: certificate, groupPrivateKey: privateKey,
      )
    }
    let text = refusal.map { "\($0)" } ?? ""
    #expect(text.hasPrefix("the group certificate \(certificate.path) can't serve TLS:"), "\(text)")
    #expect(text.contains("no explicit curve parameters"), "\(text)")
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("store/space.sqlite").path))
  }

  @Test func aGroupCertificateNeedsAnOriginToNameItsHosts() async throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    let group = try TLSIdentity.selfSigned(hosts: ["*.space.test"])
    let certificate = base.appendingPathComponent("group.pem")
    let privateKey = base.appendingPathComponent("group.key")
    try group.certificatePEM.write(to: certificate, atomically: true, encoding: .utf8)
    try group.privateKeyPEM.write(to: privateKey, atomically: true, encoding: .utf8)
    await #expect(throws: GroupTLSError.noOrigin) {
      try await SpaceServer.serve(
        folder: base.appendingPathComponent("store"), port: 0, webPort: 0, dev: true,
        groupCertificate: certificate, groupPrivateKey: privateKey,
      )
    }
  }
}

// A P-256 key and self-signed leaf spelled with explicit curve parameters
// (openssl ecparam -param_enc explicit): BoringSSL loads the pair, then
// fails every handshake with alert 80.
private let explicitCurveGroupCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIICdTCCAhugAwIBAgIUTKpO2ratpaSRsARx/3kj/FrNJrIwCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLKi5sb2NhbGhvc3QwHhcNMjYwOTI4MDMyODEzWhcNMzYwOTI1
MDMyODEzWjAWMRQwEgYDVQQDDAsqLmxvY2FsaG9zdDCCAUswggEDBgcqhkjOPQIB
MIH3AgEBMCwGByqGSM49AQECIQD/////AAAAAQAAAAAAAAAAAAAAAP//////////
/////zBbBCD/////AAAAAQAAAAAAAAAAAAAAAP///////////////AQgWsY12Ko6
k+ez671VdpiGvGUdBrDMU7D2O848PifSYEsDFQDEnTYIhucEk2pmeOETnSa3gZ9+
kARBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tK
fA+eFivOM1drMV7Oy7ZAaDe/UfUCIQD/////AAAAAP//////////vOb6racXnoTz
ucrC/GMlUQIBAQNCAATGYED7evZaLC5rinB8F08NV9z9439J6wLj7jS/qdYWBqMO
7LcjfueR8c0s/czkGSYrhtbkmhbUSyyA9Rb35opCo1MwUTAdBgNVHQ4EFgQUVnzQ
MTsXy7l6Cxiqe0c6X5k5uygwHwYDVR0jBBgwFoAUVnzQMTsXy7l6Cxiqe0c6X5k5
uygwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiBnXbQQdgot10UT
6jNF5ikBNRtihEoy4EcOgvSEYt/jKwIhAO6PSSMKW5wgqtvGIyyf2lFETzAEVema
lT/QidGsJF2V
-----END CERTIFICATE-----
"""

private let explicitCurveGroupKeyPEM = """
-----BEGIN EC PRIVATE KEY-----
MIIBaAIBAQQguGediuoxpFBK78E3ZgR1Q+U38MrWceAr0c84dnwIAgCggfowgfcC
AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
YyVRAgEBoUQDQgAExmBA+3r2Wiwua4pwfBdPDVfc/eN/SesC4+40v6nWFgajDuy3
I37nkfHNLP3M5BkmK4bW5JoW1EssgPUW9+aKQg==
-----END EC PRIVATE KEY-----
"""
