import Foundation
import GRDB
import Scratch
@testable import SpaceCore
import Testing

private let fp = "sha256:" + String(repeating: "ab", count: 32)
private let rotated = "sha256:" + String(repeating: "cd", count: 32)

@Suite
struct DeploymentTests {
  @Test func absentRecordReadsNil() async throws {
    let space = try makeSpace()
    #expect(try await space.deployment() == nil)
  }

  @Test(arguments: [DeploymentRecord.Certificate.generated, .provided])
  func writeReadRoundtrip(_ certificate: DeploymentRecord.Certificate) async throws {
    let space = try makeSpace()
    let record = DeploymentRecord(origin: "https://wuhu.example:5540", tlsFingerprint: fp, certificate: certificate)
    try await space.recordDeployment(record)
    #expect(try await space.deployment() == record)
  }

  @Test func onlyTheGeneratedCertificateIsPinned() {
    #expect(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: .generated).pin == fp)
    #expect(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: .provided).pin == nil)
    #expect(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: nil).pin == nil)
  }

  @Test func secondBootReplacesTheRecord() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: "https://old.example", tlsFingerprint: fp, certificate: .generated))
    let next = DeploymentRecord(origin: "https://new.example", tlsFingerprint: rotated, certificate: .provided)
    try await space.recordDeployment(next)
    #expect(try await space.deployment() == next)
  }

  @Test func bootWithoutOriginClearsTheStaleOrigin() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: "https://old.example", tlsFingerprint: fp, certificate: .generated))
    try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: .generated))
    #expect(try await space.deployment() == DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: .generated))
  }

  @Test func recordSurvivesReopenOfTheSameFile() async throws {
    let scratch = try ScratchFolder("space-file")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")

    let record = DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: .generated)
    try await Space.open(file: file).recordDeployment(record)
    #expect(try await Space.open(file: file).deployment() == record)
  }

  // What a server from before the certificate kind was recorded leaves behind.
  @Test func aRecordFromAnOlderServerReadsAsUnknown() async throws {
    let space = try makeSpace()
    try await olderServerBoot(space, fingerprint: fp)
    let record = try #require(try await space.deployment())
    #expect(record == DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: nil))
    #expect(record.pin == nil)
  }

  // A rollback to an older server rewrites space_deployment alone; the kind
  // recorded for the previous certificate must not carry over to the new one.
  @Test func anOlderServerRewritingTheFingerprintVoidsTheRecordedKind() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: .generated))
    try await olderServerBoot(space, fingerprint: rotated)
    let record = try #require(try await space.deployment())
    #expect(record.certificate == nil)
    #expect(record.pin == nil)
  }

  @Test func recordingAnUnknownKindForgetsTheRecordedOne() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: .generated))
    try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: fp, certificate: nil))
    #expect(try await space.deployment()?.certificate == nil)
  }

  @Test(arguments: [
    (DeploymentRecord.Certificate?.some(.generated), true),
    (.some(.provided), false),
    (nil, false),
  ])
  func offlineInviteCarriesTheFingerprintOnlyForTheGeneratedCertificate(
    _ certificate: DeploymentRecord.Certificate?, pinned: Bool,
  ) async throws {
    let scratch = try ScratchFolder("space-invite")
    defer { scratch.remove() }
    let space = try Space.open(file: scratch.url.appendingPathComponent("space.sqlite"))
    let account = try await space.addAccount(kind: .human, name: nil)
    try await space.recordDeployment(DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp, certificate: certificate))

    let (link, note) = try await UserRecovery.invite(folder: scratch.url, account: account.id.rawValue, server: nil, ttl: nil)
    #expect(link.hasPrefix("https://wuhu.example/_/enroll#token=jt_"))
    #expect(link.contains("&fp=\(fp)") == pinned)
    #expect(link.contains("fp=") == pinned)
    #expect(note?.hasPrefix(UserRecovery.unprovenCertificateNote) == (certificate == nil))
  }

  private func olderServerBoot(_ space: Space, fingerprint: String) async throws {
    try await space.writer.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO space_deployment (id, origin, tls_fingerprint) VALUES (1, ?, ?)",
        arguments: ["https://wuhu.example", fingerprint],
      )
    }
  }
}
