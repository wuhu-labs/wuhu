#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import Scratch
import SpaceCore
import Testing

@Suite
struct UserVerbTests {
  @Test func addCreatesDistinctAccountsAgainstARealFolder() async throws {
    let harness = try RecoveryHarness()
    let first = await harness.run(["user", "add", "--space", harness.folder.path, "--name", "alice"])
    #expect(first == 0)
    let second = await harness.run(["user", "add", "--space", harness.folder.path, "--name", "alice"])
    #expect(second == 0)
    #expect(await harness.stderr.text == "")

    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    let ids = lines.map { line in String(line.split(separator: " ")[1]) }
    #expect(lines.allSatisfy { $0.hasPrefix("account ac_") })
    // Account-zero is the space's first admin; the second add stays plain.
    #expect(lines[0].hasSuffix("(alice) admin"))
    #expect(lines[1].hasSuffix("(alice)"))
    #expect(ids[0] != ids[1])
    #expect(ids.allSatisfy(AccountID.isValid))

    #expect(FileManager.default.fileExists(atPath: harness.folder.appendingPathComponent("space.sqlite").path))
    let space = try harness.openSpace()
    let accounts = try await space.accounts()
    #expect(Set(accounts.map(\.id.rawValue)) == Set(ids))
    #expect(accounts.allSatisfy { $0.kind == .human && $0.name == "alice" })
    #expect(accounts.filter(\.isAdmin).count == 1)
  }

  @Test func addAdminFlagMarksTheAccount() async throws {
    let harness = try RecoveryHarness()
    #expect(await harness.run(["user", "add", "--space", harness.folder.path, "--name", "root"]) == 0)
    #expect(await harness.run(["user", "add", "--admin", "--space", harness.folder.path, "--name", "second"]) == 0)
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines.allSatisfy { $0.hasSuffix(" admin") })
    let space = try harness.openSpace()
    #expect(try await space.accounts().allSatisfy(\.isAdmin))
  }

  @Test func addRefusesTheReservedOwnerName() async throws {
    let harness = try RecoveryHarness()
    let code = await harness.run(["user", "add", "--space", harness.folder.path, "--name", "Owner"])
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("Owner is reserved"))
    let space = try harness.openSpace()
    #expect(try await space.accounts().isEmpty)
  }

  @Test func resetWipesKeysAndReadSessionsAgainstARealFolder() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: "alice")
    _ = try await seeded.addKey("ed25519:" + Data(repeating: 1, count: 32).base64EncodedString(), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let readSession = try await seeded.createReadSession(account: account.id, group: .shared, expiresAt: Date().addingTimeInterval(3600))

    let code = await harness.run(["user", "reset", "--space", harness.folder.path, account.id.rawValue])
    #expect(code == 0)
    #expect(await harness.stdout.text == "reset \(account.id.rawValue) keys 1 read-sessions 1\n")

    let space = try harness.openSpace()
    #expect(try await space.account(account.id)?.name == "alice")
    #expect(try await space.keys(account: account.id) == [])
    #expect(try await space.account(readSession: readSession, in: .shared) == nil)
  }

  @Test func resetUnknownAccountFails() async throws {
    let harness = try RecoveryHarness()
    _ = try harness.openSpace()
    let code = await harness.run(["user", "reset", "--space", harness.folder.path, "ac_missing0"])
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("no account ac_missing0"))
  }

  @Test func inviteMintsAConsumableTokenAndPrintsTheCompleteLink() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: "alice")
    let fp = "sha256:" + String(repeating: "ab", count: 32)
    try await seeded.recordDeployment(DeploymentRecord(origin: "https://wuhu.example:5540", tlsFingerprint: fp, certificate: .generated))

    let code = await harness.run(["user", "invite", "--space", harness.folder.path, account.id.rawValue])
    #expect(code == 0)
    // The link is the ONLY stdout: `wuhu user invite ... | pbcopy` must copy
    // a bare link; the expiry note rides stderr like share-login.
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    #expect(lines.count == 1)
    let envelope = try #require(EnrollmentEnvelope.parse(lines[0]))
    let identity = try await seeded.identity()
    #expect(envelope.server == "https://wuhu.example:5540")
    #expect(envelope.space == identity.rawValue)
    #expect(envelope.fingerprint == fp)
    #expect(await harness.stderr.text == "one-time link; it dies at first use or in 3600 seconds\n")

    let key = try await harness.openSpace().consumeJoinToken(JoinToken(rawValue: envelope.token), pubkey: "ed25519:" + Data(repeating: 2, count: 32).base64EncodedString())
    #expect(key.account == account.id)
    #expect(key.capabilities == [.device])
    #expect(key.createdBy == nil)
  }

  @Test func inviteServerOverridesTheRecordedOrigin() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: nil)
    let fp = "sha256:" + String(repeating: "cd", count: 32)
    try await seeded.recordDeployment(DeploymentRecord(origin: "https://wuhu.example:5540", tlsFingerprint: fp, certificate: .generated))

    let code = await harness.run([
      "user", "invite", "--space", harness.folder.path, "--server", "https://lan.example:9443/", "--ttl", "60",
      account.id.rawValue,
    ])
    #expect(code == 0)
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    let envelope = try #require(EnrollmentEnvelope.parse(lines[0]))
    #expect(envelope.server == "https://lan.example:9443")
    #expect(envelope.fingerprint == fp)
    #expect(await harness.stderr.text == "one-time link; it dies at first use or in 60 seconds\n")
  }

  @Test func inviteFromAProvidedCertificateServerCarriesNoFingerprint() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: nil)
    let fp = "sha256:" + String(repeating: "ef", count: 32)
    try await seeded.recordDeployment(DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: .provided))

    let code = await harness.run(["user", "invite", "--space", harness.folder.path, account.id.rawValue])
    #expect(code == 0)
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    #expect(!lines[0].contains("fp="))
    let envelope = try #require(EnrollmentEnvelope.parse(lines[0]))
    #expect(envelope.server == "https://wuhu.example")
    #expect(envelope.fingerprint == nil)
    #expect(await harness.stderr.text == "one-time link; it dies at first use or in 3600 seconds\n")
  }

  @Test func inviteFromARecordThatPredatesTheCertificateKindCarriesNoFingerprintAndSaysSo() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: nil)
    let fp = "sha256:" + String(repeating: "ef", count: 32)
    try await seeded.recordDeployment(DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: nil))

    let code = await harness.run(["user", "invite", "--space", harness.folder.path, account.id.rawValue])
    #expect(code == 0)
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    #expect(lines.count == 1)
    let envelope = try #require(EnrollmentEnvelope.parse(lines[0]))
    #expect(envelope.fingerprint == nil)
    #expect(await harness.stderr.text == """
    the deployment record predates certificate tracking, so this link carries no certificate fingerprint; \
    boot the server once to record it
    one-time link; it dies at first use or in 3600 seconds

    """)
  }

  @Test func inviteWithServerButNoDeploymentRecordOmitsTheFingerprint() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: nil)

    let code = await harness.run([
      "user", "invite", "--space", harness.folder.path, "--server", "https://lan.example:9443", account.id.rawValue,
    ])
    #expect(code == 0)
    let lines = await harness.stdout.text.split(separator: "\n").map(String.init)
    let envelope = try #require(EnrollmentEnvelope.parse(lines[0]))
    #expect(envelope.server == "https://lan.example:9443")
    #expect(envelope.fingerprint == nil)
  }

  @Test func inviteWithoutARecordedOriginFails() async throws {
    let harness = try RecoveryHarness()
    let seeded = try harness.openSpace()
    let account = try await seeded.addAccount(kind: .human, name: nil)

    let code = await harness.run(["user", "invite", "--space", harness.folder.path, account.id.rawValue])
    #expect(code == 1)
    let stderr = await harness.stderr.text
    #expect(stderr.contains("no server origin recorded"))
    #expect(stderr.contains("--server"))
    #expect(await harness.stdout.text == "")
  }

  @Test func inviteUnknownAccountFails() async throws {
    let harness = try RecoveryHarness()
    _ = try harness.openSpace()
    let code = await harness.run(["user", "invite", "--space", harness.folder.path, "ac_missing0"])
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("no account ac_missing0"))
  }

  @Test func missingFolderFails() async throws {
    let harness = try RecoveryHarness()
    let absent = harness.folder.appendingPathComponent("absent", isDirectory: true)
    let code = await harness.run(["user", "add", "--space", absent.path])
    #expect(code == 1)
    #expect(await harness.stderr.text.contains("no space folder"))
  }

  @Test func usageErrors() async throws {
    let harness = try RecoveryHarness()
    #expect(await harness.run(["user", "add"]) == 64)
    #expect(await harness.run(["user", "reset", "--space", harness.folder.path]) == 64)
    #expect(await harness.run(["user", "revoke"]) == 64)
    #expect(await harness.run(["user"]) == 64)
    #expect(await harness.run(["user", "invite", "ac_missing0"]) == 64)
    #expect(await harness.run(["user", "invite", "--space", harness.folder.path]) == 64)
    #expect(await harness.run(["user", "invite", "--space", harness.folder.path, "--ttl", "0", "ac_missing0"]) == 64)
    #expect(await harness.run(["user", "invite", "--space", harness.folder.path, "--server", "http://x", "ac_missing0"]) == 64)
    #expect(await harness.run(["user", "invite", "--space", harness.folder.path, "--server", "https://x/path", "ac_missing0"]) == 64)
  }
}

private struct RecoveryHarness {
  let runner: CommandRunner
  let stdout: TextSink
  let stderr: TextSink
  let scratch: ScratchFolder
  let folder: URL

  init() throws {
    self.scratch = try ScratchFolder("recovery")
    self.folder = self.scratch.url.appendingPathComponent("space", isDirectory: true)
    try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    let stdout = TextSink()
    let stderr = TextSink()
    self.stdout = stdout
    self.stderr = stderr
    self.runner = CommandRunner(
      fetch: FetchClient { _ in preconditionFailure("offline verbs must not touch the network") },
      user: { command in
        switch command {
        case let .add(folder, name, admin):
          (try await UserRecovery.add(folder: URL(fileURLWithPath: folder, isDirectory: true), name: name, admin: admin), nil)
        case let .reset(folder, account):
          (try await UserRecovery.reset(folder: URL(fileURLWithPath: folder, isDirectory: true), account: account), nil)
        case let .invite(folder, account, server, ttl):
          try await UserRecovery.invite(
            folder: URL(fileURLWithPath: folder, isDirectory: true),
            account: account,
            server: server,
            ttl: ttl.map(TimeInterval.init),
          )
        }
      },
      stdin: { "" },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: [:],
      currentDirectory: self.scratch.path,
    )
  }

  func run(_ arguments: [String]) async -> Int32 {
    await withDependencies {
      Self.liveish(&$0)
    } operation: {
      await self.runner.run(arguments: arguments)
    }
  }

  func openSpace() throws -> Space {
    try withDependencies {
      Self.liveish(&$0)
    } operation: {
      try Space.open(file: self.folder.appendingPathComponent("space.sqlite"))
    }
  }

  private static func liveish(_ values: inout DependencyValues) {
    values.date = DateGenerator { Date() }
    values.continuousClock = ContinuousClock()
    values.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
  }
}

private actor TextSink {
  private(set) var text = ""
  func append(_ chunk: String) { self.text += chunk }
}
