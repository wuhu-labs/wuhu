import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import enum PinnedTLS.PinnedTLS
import ServeNIO
import ServeTLS
import SpaceCore
import SpaceServer
import Testing

@Suite(.deterministicDependencies, .serialized) struct EnrollmentCLITests {
  @Test func enrollsFromACleanHomeAndTheTokenDiesAtEnrollment() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let account = try await rig.space.addAccount(kind: .human, name: "alice")
      let minted = try await rig.space.mintJoinToken(
        account: account.id, capabilities: [.device, .seat], createdBy: nil, lifetime: 600,
      )
      let url = "https://127.0.0.1:\(server.port)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)"

      #expect(!FileManager.default.fileExists(atPath: rig.configDirectory.path))
      let io = CLIIO(stdin: url + "\n")
      #expect(await rig.run(["login"], io: io) == 0)
      #expect(await io.stdoutText() == "enrolled \(account.id.rawValue) (device seat)\n")
      #expect(await io.stderrText().contains("wuhu use 127.0.0.1:\(server.port)"))

      let keyFile = rig.configDirectory
        .appendingPathComponent("keys", isDirectory: true)
        .appendingPathComponent(server.space + ".key")
      #expect(try posixMode(FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions]) == 0o600)
      let keysDirectory = keyFile.deletingLastPathComponent()
      #expect(try posixMode(FileManager.default.attributesOfItem(atPath: keysDirectory.path)[.posixPermissions]) == 0o700)
      #expect(try rig.trust.pin(forHost: "127.0.0.1:\(server.port)") == server.fingerprint)

      let keys = try await rig.space.keys(account: account.id)
      #expect(keys.count == 1)
      let enrolled = try #require(keys.first)
      #expect(enrolled.pubkey.hasPrefix("ed25519:"))
      #expect(enrolled.capabilities == [.device, .seat])
      #expect(try await rig.space.credential(pubkey: enrolled.pubkey) == enrolled)
      let secret = String(minted.token.rawValue.dropFirst(3))
      #expect(!enrolled.pubkey.contains(secret))

      let replay = CLIIO(stdin: url + "\n")
      #expect(await rig.run(["login"], io: replay) == 1)
      #expect(await replay.stderrText().contains("join token rejected"))
      #expect(try await rig.space.keys(account: account.id).count == 1)
    }
  }

  @Test func keysAreNeverReusedAcrossSpaces() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let otherSpace = try EnrollRig.makeSpace(seed: 71, date: rig.clock.generator)
    try await rig.serving { server in
      try await rig.serving(space: otherSpace, hosts: ["localhost"]) { otherServer in
        #expect(server.fingerprint != otherServer.fingerprint)
        #expect(server.space != otherServer.space)
        let first = try await rig.space.addAccount(kind: .human, name: nil)
        let second = try await otherSpace.addAccount(kind: .human, name: nil)
        let firstToken = try await rig.space.mintJoinToken(account: first.id, capabilities: [.device], createdBy: nil, lifetime: 600)
        let secondToken = try await otherSpace.mintJoinToken(account: second.id, capabilities: [.device], createdBy: nil, lifetime: 600)

        #expect(await rig.run(["login"], io: CLIIO(stdin: "https://127.0.0.1:\(server.port)/_/enroll#token=\(firstToken.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)\n")) == 0)
        #expect(await rig.run(["login"], io: CLIIO(stdin: "https://localhost:\(otherServer.port)/_/enroll#token=\(secondToken.token.rawValue)&space=\(otherServer.space)&fp=\(otherServer.fingerprint)\n")) == 0)

        let firstKeys = try await rig.space.keys(account: first.id)
        let secondKeys = try await otherSpace.keys(account: second.id)
        #expect(firstKeys.count == 1)
        #expect(secondKeys.count == 1)
        #expect(firstKeys.first?.pubkey != secondKeys.first?.pubkey)
        let keysDirectory = rig.configDirectory.appendingPathComponent("keys")
        let files = try FileManager.default.contentsOfDirectory(atPath: keysDirectory.path).sorted()
        #expect(files == [server.space + ".key", otherServer.space + ".key"].sorted())
      }
    }
  }

  @Test func shareLoginMintsAOneTimeQRLinkForThePhone() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let account = try await rig.space.addAccount(kind: .human, name: "alice")
      let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
      let inviteURL = "https://127.0.0.1:\(server.port)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)"
      #expect(await rig.run(["login"], io: CLIIO(stdin: inviteURL + "\n")) == 0)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")

      let io = CLIIO()
      #expect(await rig.run(["share-login"], io: io) == 0)
      let stdout = await io.stdoutText()
      #expect(stdout.contains("█"))
      let link = try #require(stdout.split(separator: "\n").last.map(String.init))
      #expect(link.hasPrefix("https://127.0.0.1:\(server.port)/_/enroll#token=jt_"))
      #expect(link.contains("&space=\(server.space)"))
      #expect(link.contains("&fp=\(server.fingerprint)"))

      let phone = try EnrollRig(sharing: rig)
      #expect(!FileManager.default.fileExists(atPath: phone.configDirectory.path))
      let phoneIO = CLIIO(stdin: link + "\n")
      #expect(await phone.run(["login"], io: phoneIO) == 0)
      #expect(await phoneIO.stdoutText() == "enrolled \(account.id.rawValue) (device)\n")
      let keys = try await rig.space.keys(account: account.id)
      #expect(keys.count == 2)
      #expect(Set(keys.map(\.pubkey)).count == 2)

      let replayer = try EnrollRig(sharing: rig)
      let replayIO = CLIIO(stdin: link + "\n")
      #expect(await replayer.run(["login"], io: replayIO) == 1)
      #expect(await replayIO.stderrText().contains("join token rejected"))
      #expect(try await rig.space.keys(account: account.id).count == 2)

      let strangerIO = CLIIO()
      let stranger = try EnrollRig(sharing: rig)
      try stranger.pinWallet(to: "127.0.0.1:\(server.port)")
      try stranger.trust.record(server.fingerprint, forHost: "127.0.0.1:\(server.port)")
      #expect(await stranger.run(["share-login"], io: strangerIO) == 1)
      #expect(await strangerIO.stderrText().contains("this device holds no key"))
    }
  }

  @Test func useAdoptsASecondAddressForAnEnrolledSpace() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let account = try await rig.space.addAccount(kind: .human, name: "alice", admin: true)
      let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device, .seat], createdBy: nil, lifetime: 600)
      let invite = "https://127.0.0.1:\(server.port)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)"
      #expect(await rig.run(["login"], io: CLIIO(stdin: invite + "\n")) == 0)

      let identities = SpaceIdentityStore(directory: rig.configDirectory)
      #expect(try identities.identity(forHost: "localhost:\(server.port)") == nil)

      let useIO = CLIIO()
      let code = await withDependencies {
        $0[ServerTrustProbe.self] = ServerTrustProbe(
          validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
          observeLeaf: { host, port in try await PinnedTLS.probeCertificate(host: host, port: port) },
        )
      } operation: {
        await rig.run(["use", "--pin", "localhost:\(server.port)"], io: useIO)
      }
      #expect(code == 0)
      #expect(try identities.identity(forHost: "localhost:\(server.port)") == server.space)

      let io = CLIIO()
      #expect(await rig.run(["share-login"], io: io) == 0)
      let link = try #require(await io.stdoutText().split(separator: "\n").last.map(String.init))
      #expect(link.hasPrefix("https://localhost:\(server.port)/_/enroll#token=jt_"))
      #expect(link.contains("&space=\(server.space)"))
    }
  }

  @Test func useRefusesAnAddressWhoseSpaceIdentityChanged() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let stale = "spc_" + String(repeating: "e", count: 32)
      let identities = SpaceIdentityStore(directory: rig.configDirectory)
      try identities.record(stale, forHost: "localhost:\(server.port)")

      let io = CLIIO()
      let code = await withDependencies {
        $0[ServerTrustProbe.self] = ServerTrustProbe(
          validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
          observeLeaf: { host, port in try await PinnedTLS.probeCertificate(host: host, port: port) },
        )
      } operation: {
        await rig.run(["use", "--pin", "localhost:\(server.port)"], io: io)
      }
      #expect(code == 1)
      let stderr = await io.stderrText()
      #expect(stderr.contains(stale))
      #expect(stderr.contains(server.space))
      #expect(stderr.contains("wuhu untrust localhost:\(server.port)"))
      #expect(try identities.identity(forHost: "localhost:\(server.port)") == stale)
      #expect(!FileManager.default.fileExists(atPath: rig.walletDirectory.path))
    }
  }

  @Test func linkMintingPrefersTheAdvertisedOrigin() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving(origin: "https://wuhu.origin.test:9443") { server in
      let account = try await rig.space.addAccount(kind: .human, name: "alice", admin: true)
      let minted = try await rig.space.mintJoinToken(account: account.id, capabilities: [.device, .seat], createdBy: nil, lifetime: 600)
      let invite = "https://127.0.0.1:\(server.port)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)&fp=\(server.fingerprint)"
      #expect(await rig.run(["login"], io: CLIIO(stdin: invite + "\n")) == 0)
      try rig.pinWallet(to: "127.0.0.1:\(server.port)")

      let shareIO = CLIIO()
      #expect(await rig.run(["share-login"], io: shareIO) == 0)
      let link = try #require(await shareIO.stdoutText().split(separator: "\n").last.map(String.init))
      #expect(link.hasPrefix("https://wuhu.origin.test:9443/_/enroll#token=jt_"))
      #expect(link.contains("&space=\(server.space)"))
      #expect(link.contains("&fp=\(server.fingerprint)"))

      let machineIO = CLIIO()
      #expect(await rig.run(["machine-v2", "add", "--name", "box"], io: machineIO) == 0)
      let machineHint = await machineIO.stderrText()
      #expect(machineHint.contains("wuhu machine-v2 join https://wuhu.origin.test:9443 \(server.fingerprint)"))
      #expect(!machineHint.contains("jt_"))
    }
  }

  // The invite token authorizes enrolling any presented key, so it must never
  // ride argv, where ps exposes it for the whole process lifetime — and the
  // rejection itself must not echo it into captured logs or transcripts.
  @Test func loginRefusesAnInviteLinkOnArgvWithoutEchoingIt() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let url = "https://127.0.0.1:1/_/enroll#token=jt_secret&fp=sha256:" + String(repeating: "a", count: 64)
    let io = CLIIO()
    #expect(await rig.run(["login", url], io: io) == 64)
    let stderr = await io.stderrText()
    #expect(stderr.contains("stdin"))
    #expect(!stderr.contains("jt_secret"))
    #expect(await io.stdoutText().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rig.configDirectory.path))
  }

  @Test func anInviteLinkParsesWithAnyOneTrailingLineTerminator() {
    let link = "https://127.0.0.1:1/_/enroll#token=jt_secret&space=spc_" + String(repeating: "a", count: 32)
      + "&fp=sha256:" + String(repeating: "a", count: 64)
    let bare = EnrollmentEnvelope.parse(link)
    #expect(bare?.token == "jt_secret")
    #expect(EnrollmentEnvelope.parse(link + "\n") == bare)
    #expect(EnrollmentEnvelope.parse(link + "\r\n") == bare)
    #expect(EnrollmentEnvelope.parse(link + "\r") == bare)
    #expect(EnrollmentEnvelope.parse(link + "\n\n") != bare)
  }

  @Test func aPreexistingLooseKeysDirectoryIsRetightened() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let store = try DeviceKeyStore(environment: ["WUHU_CONFIG_DIR": rig.configDirectory.path])
    try FileManager.default.createDirectory(
      at: store.directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755],
    )
    _ = try store.loadOrCreate(space: "spc_" + String(repeating: "b", count: 32))
    #expect(try posixMode(FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions]) == 0o700)
  }

  @Test func aLooseKeysDirectoryHoldingAKeyIsRefused() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let store = try DeviceKeyStore(environment: ["WUHU_CONFIG_DIR": rig.configDirectory.path])
    let identity = "spc_" + String(repeating: "c", count: 32)
    _ = try store.loadOrCreate(space: identity)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
    do {
      _ = try store.loadOrCreate(space: identity)
      Issue.record("a loose keys directory holding a key must be refused")
    } catch let error as CLIError {
      #expect(error.message.contains("chmod 700"))
    }
  }

  @Test func aLooseKeyFileIsRefused() async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    let store = try DeviceKeyStore(environment: ["WUHU_CONFIG_DIR": rig.configDirectory.path])
    let identity = "spc_" + String(repeating: "a", count: 32)
    let first = try store.loadOrCreate(space: identity)
    let again = try store.loadOrCreate(space: identity)
    #expect(first.pubkeyLabel == again.pubkeyLabel)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: store.keyFile(space: identity).path,
    )
    #expect(throws: (any Error).self) {
      _ = try store.load(space: identity)
    }
  }
}

@Suite(.deterministicDependencies)
struct ShareLoginParsingTests {
  @Test func defaultsToNoTTL() throws {
    #expect(try Command.parse(["share-login"]) == .shareLogin(ttl: nil))
  }

  @Test func parsesTTLSeconds() throws {
    #expect(try Command.parse(["share-login", "--ttl", "86400"]) == .shareLogin(ttl: 86400))
    #expect(try Command.parse(["share-login", "--ttl", "259200"]) == .shareLogin(ttl: 259_200))
  }

  @Test(arguments: [
    ["share-login", "--ttl", "0"],
    ["share-login", "--ttl", "-60"],
    ["share-login", "--ttl", "259201"],
    ["share-login", "--ttl", "soon"],
    ["share-login", "--ttl"],
    ["share-login", "extra"],
  ])
  func rejectsABadTTL(_ arguments: [String]) {
    #expect(throws: UsageError.self) {
      try Command.parse(arguments)
    }
  }

  @Test func lifetimePhraseScalesWithTheTTL() {
    #expect(lifetimePhrase(seconds: 600) == "10 minutes")
    #expect(lifetimePhrase(seconds: 59) == "1 minute")
    #expect(lifetimePhrase(seconds: 3600) == "1 hour")
    #expect(lifetimePhrase(seconds: 7200) == "2 hours")
    #expect(lifetimePhrase(seconds: 86400) == "1 day")
    #expect(lifetimePhrase(seconds: 259_200) == "3 days")
  }
}
