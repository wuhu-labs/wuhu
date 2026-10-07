#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import SpaceCore
import Testing

@Suite(.serialized) struct PersonaCLITests {
  func enroll(_ rig: EnrollRig, port: Int, space: String, fingerprint: String, admin: Bool = false) async throws {
    let account = try await rig.space.addAccount(kind: .human, name: nil, admin: admin)
    let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let url = "https://127.0.0.1:\(port)/_/enroll#token=\(minted.token.rawValue)&space=\(space)&fp=\(fingerprint)"
    #expect(await rig.run(["login"], io: CLIIO(stdin: url + "\n")) == 0)
  }

  func usePersona(_ rig: EnrollRig, port: Int) async throws -> String {
    let io = CLIIO()
    #expect(await rig.run(["use", "127.0.0.1:\(port)"], io: io) == 0)
    let line = try #require(await io.stdoutText().split(separator: "\n").first.map(String.init))
    let persona = try #require(line.range(of: " as ").map { String(line[$0.upperBound...]) })
    let parts = persona.split(separator: "-")
    #expect(parts.count >= 3, "expected an allocator word-name, got: \(persona)")
    #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLowercase) })
    return persona
  }

  func cachedPersonas(_ rig: EnrollRig) throws -> [String: String] {
    let file = rig.walletDirectory.appendingPathComponent("personas.json")
    return try JSONDecoder().decode([String: String].self, from: try Data(contentsOf: file))
  }

  @Test func useMintsAServerPersonaOnceAndReusesTheCache() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let first = try await usePersona(rig, port: server.port)

      let record = try #require(try await rig.space.persona(named: first))
      let keys = try await rig.space.keys(account: record.account)
      #expect(keys.map(\.pubkey) == [record.key])
      #expect(try cachedPersonas(rig).values.contains(first))

      let again = try await usePersona(rig, port: server.port)
      #expect(again == first)
    }
  }

  @Test func aHandleNamesThePersonaAndTheProfileReadsItBack() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let persona = try await usePersona(rig, port: server.port)

      let claim = CLIIO()
      #expect(await rig.run(["user", "handle", "Morgan", "--display-name", "Lee, Morgan"], io: claim) == 0)
      #expect(await claim.stdoutText() == "handle @morgan (\(persona))\n")

      let profile = CLIIO()
      #expect(await rig.run(["user", "profile"], io: profile) == 0)
      #expect(await profile.stdoutText() == "@morgan \(persona) Lee, Morgan\n")

      let refused = CLIIO()
      #expect(await rig.run(["user", "handle", "-nope"], io: refused) == 1)
      #expect(await refused.stderrText().contains("invalidHandle"))
    }
  }

  @Test func aWalletOptInAnnouncesTheEnrolledPersonaAndActsAsItsHuman() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint, admin: true)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
      let io = CLIIO()
      let code = await rig.run(["user", "list"], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      let stderr = await io.stderrText()
      #expect(code == 0, "\(stderr)")
      let persona = try #require(try cachedPersonas(rig).values.first)
      #expect(await io.stderrText() == "acting as \(persona) (wallet)\n")
      let account = try #require(try await rig.space.accounts().first)
      #expect(await io.stdoutText().contains(account.id.rawValue))
    }
  }

  @Test func aWalletOptInDoesNotAnnounceAnOwnerWhenPersonaMintingIsRejected() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(dev: true) { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
      let account = try #require(try await rig.space.accounts().first)
      let key = try #require(try await rig.space.keys(account: account.id).first)
      try await rig.space.removeKey(pubkey: key.pubkey)
      let io = CLIIO()
      let code = await rig.run(["user", "list"], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      #expect(code == 1)
      #expect(await io.stderrText().contains("unauthorized"))
      #expect(!(await io.stderrText()).contains("acting as"))
      #expect(await io.stdoutText().isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func aWalletOptInRepinsWithoutLookingUpTheUnreachableOrMalformedOldSpace(malformed: Bool) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
    }
    #expect(!FileManager.default.fileExists(atPath: rig.walletDirectory.appendingPathComponent("personas.json").path))
    if malformed {
      try Data("{".utf8).write(to: rig.walletDirectory.appendingPathComponent("config.json"))
    }
    let destination = try EnrollRig.makeSpace(seed: 30, date: rig.clock.generator)
    try await rig.serving(space: destination) { server in
      let host = "127.0.0.1:\(server.port)"
      try rig.trust.record(server.fingerprint, forHost: host)
      let io = CLIIO()
      let code = await rig.run(["use", host], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      let stderr = await io.stderrText()
      #expect(code == 0, "\(stderr)")
      #expect(stderr == "acting as anonymous (wallet)\n")
      #expect(await io.stdoutText().hasPrefix("pinned \(host) ->"))
      let config = try Data(contentsOf: rig.walletDirectory.appendingPathComponent("config.json"))
      #expect(try JSONDecoder().decode([String: String].self, from: config)["space"] == host)
    }
  }

  @Test func anAnonymousExplicitTargetNeverBorrowsThePinnedSpacesCachedPersona() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    var oldPersona = ""
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      oldPersona = try await usePersona(rig, port: server.port)
    }
    let destination = try EnrollRig.makeSpace(seed: 30, date: rig.clock.generator)
    _ = try await destination.fs(.shared).write("/file.txt", Data("from B".utf8), ifMatch: nil)
    try await rig.serving(space: destination, dev: true) { server in
      let host = "127.0.0.1:\(server.port)"
      try rig.trust.record(server.fingerprint, forHost: host)
      let io = CLIIO()
      let code = await rig.run(["cat", "https://\(host)/file.txt"], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      let stderr = await io.stderrText()
      #expect(code == 0, "\(stderr)")
      #expect(await io.stdoutText() == "from B")
      #expect(stderr == "acting as anonymous (wallet)\n")
      #expect(!stderr.contains(oldPersona))
    }
  }

  @Test(arguments: [false, true])
  func walletLoginWorksOverAMalformedOrDeadPin(malformed: Bool) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
    }
    if malformed {
      try Data("{".utf8).write(to: rig.walletDirectory.appendingPathComponent("config.json"))
    }
    let destination = try EnrollRig.makeSpace(seed: 30, date: rig.clock.generator)
    try await rig.serving(space: destination) { server in
      let account = try await destination.addAccount(kind: .human, name: nil)
      let minted = try await destination.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
      let url = "https://127.0.0.1:\(server.port)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)"
      let io = CLIIO(stdin: url + "\n")
      let code = await rig.run(["login"], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      #expect(code == 0)
      #expect(await io.stdoutText().contains("enrolled \(account.id.rawValue)"))
      #expect(await io.stderrText().contains("acting as the local user (wallet)\n"))
    }
  }

  @Test(arguments: [false, true])
  func anAddressedCommandAnnouncesItsEnrolledTargetWithOrWithoutAPin(unpinned: Bool) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try rig.pinWallet(to: "old.test")
    var wallet = Wallet(directory: rig.walletDirectory)
    try wallet.recordPersona("old-pin-persona", space: "old.test")
    if unpinned {
      try FileManager.default.removeItem(at: rig.walletDirectory.appendingPathComponent("config.json"))
    }
    _ = try await rig.space.fs(.shared).write("/file.txt", Data("addressed target".utf8), ifMatch: nil)
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let io = CLIIO()
      let arguments = ["--group", "shared", "cat", "wuhu://127.0.0.1:\(server.port)/file.txt"]
      let code = await rig.run(arguments, io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      let stderr = await io.stderrText()
      #expect(code == 0, "\(stderr)")
      #expect(await io.stdoutText() == "addressed target")
      let target = try #require(try cachedPersonas(rig).first { $0.key != "old.test" }?.value)
      #expect(try await rig.space.persona(named: target) != nil)
      #expect(stderr == "acting as \(target) (wallet)\n")
      #expect(!stderr.contains("old-pin-persona"))
    }
  }

  @Test func aWalletOptInRejectsAMalformedPersonaCacheForItsAuthenticatedTarget() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")
      try Data("{".utf8).write(to: rig.walletDirectory.appendingPathComponent("personas.json"))
      let io = CLIIO()
      let code = await rig.run(["user", "list"], io: io, environment: ["WUHU_EXEC": "1", "WUHU_IDENTITY": "wallet"])
      #expect(code == 64)
      #expect(await io.stderrText().contains("personas.json; fix or remove it"))
      #expect(!(await io.stderrText()).contains("acting as"))
      #expect(await io.stdoutText().isEmpty)
    }
  }

  @Test func twoEnrolledSeatsDrawDistinctPersonas() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let second = try EnrollRig(sharing: rig)
    try await rig.serving { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      try await enroll(second, port: server.port, space: server.space, fingerprint: server.fingerprint)
      let first = try await usePersona(rig, port: server.port)
      let other = try await usePersona(second, port: server.port)
      #expect(first != other)
    }
  }

  @Test func aServerRejectedKeyDegradesToOwnerInsteadOfCrashing() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(dev: true) { server in
      try await enroll(rig, port: server.port, space: server.space, fingerprint: server.fingerprint)
      // The documented reset: the space forgets the key while the device key
      // file survives (the space id is unchanged), so bearerSource still
      // loads it but the mint is rejected. An identity verb must still
      // succeed — attributing to the owner — not 401-crash.
      let account = try #require(try await rig.space.accounts().first)
      let key = try #require(try await rig.space.keys(account: account.id).first)
      try await rig.space.removeKey(pubkey: key.pubkey)

      let io = CLIIO()
      #expect(await rig.run(["use", "127.0.0.1:\(server.port)"], io: io) == 0)
      let line = try #require(await io.stdoutText().split(separator: "\n").first.map(String.init))
      #expect(!line.contains(" as "))
      #expect(await io.stderrText().isEmpty)
      #expect(!FileManager.default.fileExists(
        atPath: rig.walletDirectory.appendingPathComponent("personas.json").path,
      ))
    }
  }

  @Test func anUnenrolledSeatPinsWithoutAPersona() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      try rig.trust.record(server.fingerprint, forHost: "127.0.0.1:\(server.port)")
      let io = CLIIO()
      #expect(await rig.run(["use", "127.0.0.1:\(server.port)"], io: io) == 0)
      let line = try #require(await io.stdoutText().split(separator: "\n").first.map(String.init))
      #expect(!line.contains(" as "))
      #expect(!FileManager.default.fileExists(
        atPath: rig.walletDirectory.appendingPathComponent("personas.json").path,
      ))
    }
  }
}
