import DeterministicDependencies
import Foundation
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct SpaceIdentityTests {
  @Test func mintedIdentityHasTheOpaqueSpcShape() async throws {
    let space = try makeSpace()
    let identity = try await space.identity()
    #expect(SpaceIdentity.isValid(identity.rawValue))
  }

  @Test func identityIsStableAcrossReopenOfTheSameFile() async throws {
    let scratch = try ScratchFolder("space-file")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")

    let space = try Space.open(file: file)
    let first = try await space.identity()
    try await space.close()
    let reopened = try Space.open(file: file)
    #expect(try await reopened.identity() == first)
    try await reopened.close()
  }

  @Test func twoSpacesMintDistinctIdentities() async throws {
    let a = try makeSpace()
    let b = try makeSpace()
    #expect(try await a.identity() != (try await b.identity()))
  }

  @Test func explicitIdentitySeedsOnceAndRefusesMismatch() async throws {
    let scratch = try ScratchFolder("explicit-space")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    let identity = SpaceIdentity(rawValue: "spc_" + String(repeating: "a", count: 32))
    let seeded = try Space.open(file: file, identity: identity)
    #expect(try await seeded.identity() == identity)
    try await seeded.close()
    let reopened = try Space.open(file: file)
    #expect(try await reopened.identity() == identity)
    try await reopened.close()
    let other = SpaceIdentity(rawValue: "spc_" + String(repeating: "b", count: 32))
    #expect(throws: SpaceIdentityError.mismatch(expected: other.rawValue, actual: identity.rawValue)) {
      try Space.open(file: file, identity: other)
    }
    let refused = try Space.open(file: file)
    #expect(try await refused.identity() == identity)
    try await refused.close()
  }

  @Test func invalidExplicitIdentityDoesNotCreateFile() throws {
    let scratch = try ScratchFolder("explicit-space-invalid")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    #expect(throws: SpaceIdentityError.invalid("invalid")) {
      try Space.open(file: file, identity: SpaceIdentity(rawValue: "invalid"))
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func onDiskSpaceOpensInWALJournalMode() async throws {
    let scratch = try ScratchFolder("space-file")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")

    let space = try Space.open(file: file)
    let mode = try space.database.accessWriter(label: "test.writer") { try MigrationDB(handle: $0).string("PRAGMA journal_mode") }
    #expect(mode == "wal")
    try await space.close()
  }
}
