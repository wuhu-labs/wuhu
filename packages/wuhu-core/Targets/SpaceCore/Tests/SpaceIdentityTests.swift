import Foundation
import Scratch
@testable import SpaceCore
import Testing

@Suite
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

    let first = try await Space.open(file: file).identity()
    let reopened = try await Space.open(file: file).identity()
    #expect(first == reopened)
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
    #expect(try await Space.open(file: file, identity: identity).identity() == identity)
    #expect(try await Space.open(file: file).identity() == identity)
    let other = SpaceIdentity(rawValue: "spc_" + String(repeating: "b", count: 32))
    #expect(throws: SpaceIdentityError.mismatch(expected: other.rawValue, actual: identity.rawValue)) {
      try Space.open(file: file, identity: other)
    }
    #expect(try await Space.open(file: file).identity() == identity)
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
    let mode = try await space.writer.read { db in
      try String.fetchOne(db, sql: "PRAGMA journal_mode")
    }
    #expect(mode == "wal")
  }
}
