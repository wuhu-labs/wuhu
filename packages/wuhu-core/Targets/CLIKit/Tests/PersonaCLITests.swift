#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import SpaceCore
import Testing

@Suite(.serialized) struct PersonaCLITests {
  func enroll(_ rig: EnrollRig, port: Int, space: String, fingerprint: String) async throws {
    let account = try await rig.space.addAccount(kind: .human, name: nil)
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
