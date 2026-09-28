#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Assertion.AssertionClaims
import struct Assertion.SignedAssertion
@testable import CLIKit
import Crypto
import Scratch
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
