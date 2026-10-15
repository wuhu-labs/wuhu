#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Assertion.AssertionClaims
import struct Assertion.SignedAssertion
@testable import CLIKit
import Crypto
import Dependencies
import Fetch
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import Scratch
import struct SpaceClient.ExecSession
import struct SpaceClient.SpaceClient
import SpaceCore
import Testing

@Suite(.serialized) struct AssertionCLITests {
  func enroll(_ rig: EnrollRig, port: Int, space: String, fingerprint: String) async throws -> String {
    let account = try await rig.space.addAccount(kind: .human, name: "alice")
    let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let url = "https://127.0.0.1:\(port)/_/enroll#token=\(minted.token.rawValue)&space=\(space)&fp=\(fingerprint)"
    #expect(await rig.run(["login"], io: CLIIO(stdin: url + "\n")) == 0)
    try rig.pinWallet(to: "127.0.0.1:\(port)")
    return try #require(try await rig.space.keys(account: account.id).first?.pubkey)
  }

  func cachedAssertion(_ rig: EnrollRig) throws -> SignedAssertion {
    let file = rig.walletDirectory.appendingPathComponent("assertions.json")
    let cache = try JSONDecoder().decode([String: String].self, from: try Data(contentsOf: file))
    let raw = try #require(cache.values.first)
    return try #require(SignedAssertion(rawValue: raw))
  }

  func assertionFileMode(_ rig: EnrollRig) throws -> Int {
    let file = rig.walletDirectory.appendingPathComponent("assertions.json")
    return try #require(posixMode(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]))
  }

  @Test func anExpiredAssertionRemintsTransparentlyWithNoServerRoundTrip() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)

      #expect(await rig.run(["ls", "/"]) == 0)
      let first = try cachedAssertion(rig)
      #expect(first.claims.space == server.space)
      #expect(first.claims.expiresAt == rig.clock.current.addingTimeInterval(3600))

      rig.clock.advance(by: 7200)
      let log = RequestLog()
      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io, log: log) == 0)
      #expect(await io.stderrText().isEmpty)
      #expect(log.recorded == ["/v1/tools/ls"])

      let second = try cachedAssertion(rig)
      #expect(second != first)
      #expect(second.claims.key == first.claims.key)
      #expect(second.claims.expiresAt == rig.clock.current.addingTimeInterval(3600))
    }
  }

  @Test func theAssertionCacheIsOwnerOnlyAcrossMintAndRemint() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)
      #expect(try assertionFileMode(rig) == 0o600)

      rig.clock.advance(by: 7200)
      #expect(await rig.run(["ls", "/"]) == 0)
      #expect(try assertionFileMode(rig) == 0o600)
    }
  }

  @Test func aLooseAssertionCacheIsDroppedAndRewrittenOwnerOnly() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 0)
      let stderr = await io.stderrText()
      #expect(stderr.contains("not owner-only"))
      #expect(stderr.contains("may already have been read"))
      #expect(stderr.contains("does not revoke"))
      #expect(stderr.contains("wuhu user reset"))
      #expect(try assertionFileMode(rig) == 0o600)
    }
  }

  @Test func aLooseCacheEntryIsNeverLaunderedIntoTheTightenedFile() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      let planted = try JSONEncoder().encode(["sha256:planted": "planted-assertion"])
      #expect(FileManager.default.createFile(
        atPath: file.path,
        contents: planted,
        attributes: [.posixPermissions: 0o644],
      ))

      #expect(await rig.run(["ls", "/"]) == 0)
      let cache = try JSONDecoder().decode([String: String].self, from: try Data(contentsOf: file))
      #expect(cache["sha256:planted"] == nil)
      #expect(Set(cache.keys) == ["127.0.0.1:\(server.port)"])
      #expect(try assertionFileMode(rig) == 0o600)
    }
  }

  @Test func aSymlinkedCacheDoesNotFailTheVerbAndIsNotWrittenThrough() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      let decoy = rig.walletDirectory.appendingPathComponent("decoy.json")
      let decoyBytes = try JSONEncoder().encode([String: String]())
      try decoyBytes.write(to: decoy)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: decoy.path)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: decoy)

      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 0)
      #expect(await io.stderrText().contains("symlink"))
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
      #expect(target == decoy.path)
      #expect(try Data(contentsOf: decoy) == decoyBytes)
    }
  }

  @Test func aReadOnlyWalletDirectoryDoesNotFailTheVerb() async throws {
    let rig = try EnrollRig()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.walletDirectory.path)
      rig.cleanUp()
    }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      try FileManager.default.removeItem(at: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.walletDirectory.path)

      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 0)
      #expect(await io.stderrText().contains("could not cache"))
      #expect(!FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test func aTornAssertionCacheWarnsAndRemintsInsteadOfCrashing() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      let whole = try Data(contentsOf: file)
      try whole.prefix(whole.count / 2).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 0)
      #expect(await io.stderrText().contains("malformed"))
      #expect(try cachedAssertion(rig).claims.space == server.space)
      #expect(try assertionFileMode(rig) == 0o600)
    }
  }

  @Test func posixModeReadsBothBridgedAndNativeAttributeValues() throws {
    #expect(posixMode(Int(0o600)) == 0o600)
    #expect(posixMode(UInt(0o644)) == 0o644)
    #expect(posixMode(nil) == nil)
    #expect(posixMode("600") == nil)

    let scratch = try ScratchFolder("posix-mode")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("file")
    #expect(FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o640]))
    #expect(posixMode(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) == 0o640)
  }

  @Test func aKickedKeyFailsMidSessionWithATeachingError() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let pubkey = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)

      try await rig.space.removeKey(pubkey: pubkey)
      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 1)
      let stderr = await io.stderrText()
      #expect(stderr.contains("revoked"))
      #expect(stderr.contains(server.space))
      #expect(stderr.contains("wuhu login"))
    }
  }

  @Test func aMissingDeviceKeyAtRemintTeachesReenrollment() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)

      let keyFile = rig.configDirectory
        .appendingPathComponent("keys", isDirectory: true)
        .appendingPathComponent(server.space + ".key")
      try FileManager.default.removeItem(at: keyFile)
      rig.clock.advance(by: 7200)

      let log = RequestLog()
      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io, log: log) == 1)
      let stderr = await io.stderrText()
      #expect(stderr.contains("no device key"))
      #expect(stderr.contains("wuhu login"))
      #expect(log.recorded.isEmpty)
    }
  }

  // A space reset re-mints the space id; after a correct re-enroll the wallet
  // may still hold a live cached assertion carrying the OLD id. The
  // authoritative SpaceIdentityStore must win, or the stale cache shadows the
  // live id and mints permanently-rejected assertions.
  @Test func aStaleCachedAssertionDoesNotShadowAReenrolledSpaceId() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)

      let staleKey = Curve25519.Signing.PrivateKey()
      let stale = try AssertionClaims(
        key: "ed25519:" + staleKey.publicKey.rawRepresentation.base64EncodedString(),
        space: "spc_" + String(repeating: "0", count: 32),
        expiresAt: rig.clock.current.addingTimeInterval(3600),
      ).signed(by: staleKey).rawValue
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      let planted = try JSONEncoder().encode(["127.0.0.1:\(server.port)": stale])
      #expect(FileManager.default.createFile(atPath: file.path, contents: planted, attributes: [.posixPermissions: 0o600]))

      #expect(await rig.run(["ls", "/"]) == 0)
      #expect(try cachedAssertion(rig).claims.space == server.space)
    }
  }

  @Test func releaseFormatCredentialsMigrateAuthenticateAndRemainReadableByThePreviousCLIWithoutLoggingSecrets() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      #expect(await rig.run(["ls", "/"]) == 0)
      let expired = try cachedAssertion(rig)
      rig.clock.advance(by: 7200)
      #expect(await rig.run(["ls", "/"]) == 0)
      let fresh = try cachedAssertion(rig)
      let file = rig.walletDirectory.appendingPathComponent("assertions.json")
      // The dev.119 Wallet writes this dictionary with raw server spellings.
      let fixture = ["https://space.example": expired.rawValue, "space.example:443": fresh.rawValue]
      try JSONEncoder().encode(fixture).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      try SpaceIdentityStore(directory: rig.configDirectory).record(server.space, forHost: "space.example:443")
      try rig.pinWallet(to: "https://space.example")
      let keyFile = rig.configDirectory.appendingPathComponent("keys/" + server.space + ".key")
      try FileManager.default.removeItem(at: keyFile)
      let local = SpaceTransport.fetchClient(trust: rig.trust, timeout: .seconds(10), plain: FetchClient { _ in
        throw FetchError.unimplemented
      })
      let forwarding = FetchClient { request in
        var request = request
        request.url = try #require(URL(string: "https://127.0.0.1:\(server.port)" + request.url.path))
        return try await local(request)
      }
      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io, plain: forwarding) == 0)
      let merged = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
      #expect(Set(merged.keys) == ["space.example:443"])
      #expect(try assertionFileMode(rig) == 0o600)
      let stdout = await io.stdoutText()
      let stderr = await io.stderrText()
      let output = stdout + stderr
      #expect(!output.contains(expired.rawValue))
      #expect(!output.contains(fresh.rawValue))
      #expect(!output.contains("Bearer "))
      #expect(!output.contains("PRIVATE KEY"))

      // Frozen previous-release reader: decode [String: String], exact-key lookup.
      let legacyRaw = try #require(merged["space.example:443"])
      #expect(legacyRaw == fresh.rawValue)
      var request = Request(url: try #require(URL(string: "https://127.0.0.1:\(server.port)/v1/tools/ls")), method: .post)
      request.headers.setSensitive(.authorization, "Bearer " + legacyRaw)
      request.body = try .json(["path": "/"])
      let response = try await local(request)
      #expect(response.status.code == 200)
    }
  }

  @Test(arguments: ["assertion expired; run the command again", "assertion signature rejected"])
  func aServer401NamesTheServerAndTeachesReauthenticationOnlyForExpiry(_ message: String) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let io = CLIIO()
      let requests = RequestLog()
      let runner = CommandRunner(
        fetch: FetchClient { request in
          requests.record(request.url.path)
          let body: JSONValue = ["code": "unauthorized", "message": .string(message)]
          return try Response.json(body, status: .unauthorized)
        },
        stdin: { "" }, stdout: { _ in }, stderr: { await io.appendErr(Array($0.utf8)) },
        environment: ["HOME": rig.root.appendingPathComponent("home").path, "WUHU_CONFIG_DIR": rig.configDirectory.path],
        currentDirectory: rig.root.appendingPathComponent("work").path,
      )
      let code = await withDependencies {
        $0.date = rig.clock.generator
        $0.continuousClock = ContinuousClock()
      } operation: {
        await runner.run(arguments: ["ls", "/"])
      }
      #expect(code == 1)
      #expect(requests.recorded == ["/v1/tools/ls"])
      let stderr = await io.stderrText()
      if message.hasPrefix("assertion expired") {
        #expect(stderr.contains("assertion expired for 127.0.0.1:\(server.port)"))
        #expect(stderr.contains("re-authenticate"))
        #expect(stderr.contains("wuhu login < invite-link"))
        #expect(!stderr.contains("run the command again"))
      } else {
        #expect(stderr.contains("unauthorized: " + message))
        #expect(!stderr.contains("re-authenticate"))
      }
    }
  }

  @Test func anExpiredWebSocketAssertionRemainsAFinalRefusalWithoutRedial() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      _ = try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let dials = RequestLog()
      let runner = CommandRunner(
        fetch: FetchClient { _ in throw FetchError.unimplemented },
        stdin: { "" }, stdout: { _ in }, stderr: { _ in },
        dial: { _, _ in
          dials.record("dial")
          throw SpaceClient.DialRefusal(status: 401, body: Array(#"{"code":"unauthorized","message":"assertion expired; run the command again"}"#.utf8))
        },
        environment: ["HOME": rig.root.appendingPathComponent("home").path, "WUHU_CONFIG_DIR": rig.configDirectory.path],
        currentDirectory: rig.root.appendingPathComponent("work").path,
      )
      let termination = try await withDependencies {
        $0.date = rig.clock.generator
        $0.continuousClock = ContinuousClock()
      } operation: {
        var wallet = Wallet(directory: rig.walletDirectory)
        var executor = Executor(runner: runner, wallet: &wallet)
        let client = try await executor.authenticated("127.0.0.1:\(server.port)")
        let start = ExecStart(id: ExecID(rawValue: "ex_abcdefgh"), cwd: "/", command: ["true"], env: nil, secrets: nil, window: nil, maxOutput: nil, timeout: nil)
        return try await ExecSession(client: client, start: start).run(input: nil) { _, _ in }
      }
      guard case let .streamFailed(message) = termination else {
        Issue.record("expected a final assertion refusal, got \(termination)")
        return
      }
      #expect(message.contains("assertion expired for 127.0.0.1:\(server.port)"))
      #expect(message.contains("wuhu login"))
      #expect(dials.recorded == ["dial"])
    }
  }

  @Test func anUnenrolledFolderStaysAnonymousAndHitsTheWall() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
      try rig.trust.record(server.fingerprint, forHost: "127.0.0.1:\(server.port)")
      let io = CLIIO()
      #expect(await rig.run(["ls", "/"], io: io) == 1)
      let stderr = await io.stderrText()
      #expect(stderr.contains("enrolled devices"))
      #expect(!FileManager.default.fileExists(
        atPath: rig.walletDirectory.appendingPathComponent("assertions.json").path,
      ))
    }
  }
}
