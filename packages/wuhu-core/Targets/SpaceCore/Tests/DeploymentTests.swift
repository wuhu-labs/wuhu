import Foundation
import Scratch
@testable import SpaceCore
import Testing

private let fp = "sha256:" + String(repeating: "ab", count: 32)

@Suite
struct DeploymentTests {
  @Test func absentRecordReadsNil() async throws {
    let space = try makeSpace()
    #expect(try await space.deployment() == nil)
  }

  @Test func writeReadRoundtrip() async throws {
    let space = try makeSpace()
    let record = DeploymentRecord(origin: "https://wuhu.example:5540", tlsFingerprint: fp)
    try await space.recordDeployment(record)
    #expect(try await space.deployment() == record)
  }

  @Test func secondBootReplacesTheRecord() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: "https://old.example", tlsFingerprint: fp))
    let rotated = "sha256:" + String(repeating: "cd", count: 32)
    try await space.recordDeployment(DeploymentRecord(origin: "https://new.example", tlsFingerprint: rotated))
    #expect(try await space.deployment() == DeploymentRecord(origin: "https://new.example", tlsFingerprint: rotated))
  }

  @Test func bootWithoutOriginClearsTheStaleOrigin() async throws {
    let space = try makeSpace()
    try await space.recordDeployment(DeploymentRecord(origin: "https://old.example", tlsFingerprint: fp))
    try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: fp))
    #expect(try await space.deployment() == DeploymentRecord(origin: nil, tlsFingerprint: fp))
  }

  @Test func recordSurvivesReopenOfTheSameFile() async throws {
    let scratch = try ScratchFolder("space-file")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")

    let record = DeploymentRecord(origin: "https://wuhu.example", tlsFingerprint: fp)
    try await Space.open(file: file).recordDeployment(record)
    #expect(try await Space.open(file: file).deployment() == record)
  }
}
