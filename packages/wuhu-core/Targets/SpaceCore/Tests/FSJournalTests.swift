import Foundation
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct JournalAlgebraTests {
  @Test func historicalReadIsStableForever() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/note.md", "one")
    let rev1 = Rev(token1.rev!)
    _ = try await space.writeText("/note.md", "two")
    _ = try await space.writeText("/note.md", "three")

    #expect(try await space.readText("/note.md", at: rev1) == "one")
    #expect(try await space.readText("/note.md") == "three")
  }

  @Test func checkoutThenReadEqualsReadAtRevision() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/doc.md", "alpha")
    let rev1 = Rev(token1.rev!)
    _ = try await space.writeText("/doc.md", "beta")

    let readAtRev = try await space.readText("/doc.md", at: rev1)
    _ = try await space.checkout(path("/doc.md"), rev: rev1, in: .shared, acting: .shared)
    let liveAfterCheckout = try await space.readText("/doc.md")

    #expect(readAtRev == "alpha")
    #expect(liveAfterCheckout == "alpha")
  }

  @Test func historyIsAppendOnly() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/log.md", "a")
    _ = try await space.writeText("/log.md", "b")
    let afterTwoWrites = try await space.history(path("/log.md"), in: .shared)
    try await space.fs(.shared).delete("/log.md", ifMatch: nil)
    let afterDelete = try await space.history(path("/log.md"), in: .shared)

    #expect(afterTwoWrites.count == 2)
    #expect(afterDelete.count == 3)
    #expect(Array(afterDelete.prefix(2)).map(\.0) == afterTwoWrites.map(\.0))
    if case .delete = afterDelete[2].2 {} else { Issue.record("last change should be a delete") }
  }

  @Test func historyRecordsMoveProvenance() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a.md", "x")
    try await space.fs(.shared).move("/a.md", to: "/b.md")

    let source = try await space.history(path("/a.md"), in: .shared)
    #expect(source.map(\.2).last == .move(to: "/b.md"))
    let destination = try await space.history(path("/b.md"), in: .shared)
    guard case .write = destination.last?.2 else {
      Issue.record("destination should end in a write, got \(String(describing: destination.last))")
      return
    }
  }

  @Test func subtreeMoveRecordsPerNodeProvenance() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/d/x.md", "x")
    try await space.fs(.shared).move("/d", to: "/e")
    #expect(try await space.history(path("/d/x.md"), in: .shared).last?.2 == .move(to: "/e/x.md"))
    #expect(try await space.history(path("/d"), in: .shared).last?.2 == .move(to: "/e"))
  }

  @Test func historyRecordsCheckoutProvenance() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/doc.md", "v1")
    let rev1 = Rev(token1.rev!)
    _ = try await space.writeText("/doc.md", "v2")
    _ = try await space.checkout(path("/doc.md"), rev: rev1, in: .shared, acting: .shared)

    let entries = try await space.history(path("/doc.md"), in: .shared)
    #expect(entries.last?.2 == .checkout(fromRev: rev1.value))
  }

  @Test func checkoutRestoringNonexistenceRecordsCheckoutProvenance() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/other.md", "x")
    let before = Rev(try await space.currentRevision())
    _ = try await space.writeText("/late.md", "born after")

    _ = try await space.checkout(path("/late.md"), rev: before, in: .shared, acting: .shared)
    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).read("/late.md") }
    #expect(try await space.history(path("/late.md"), in: .shared).last?.2 == .checkout(fromRev: before.value))
  }

  @Test func historicalViewsRejectUnknownRevisions() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a.md", "x")
    let bogus = Rev(try await space.currentRevision() + 99)

    await #expect(throws: SpaceError.invalidRevision(bogus.value)) {
      _ = try await space.fs(.shared, at: bogus).read("/a.md")
    }
    await #expect(throws: SpaceError.invalidRevision(bogus.value)) {
      _ = try await space.fs(.shared, at: bogus).list("/")
    }
    await #expect(throws: SpaceError.invalidRevision(bogus.value)) {
      _ = try await space.fs(.shared, at: bogus).stat("/a.md")
    }
  }

  @Test func deleteYields404WhileHistoricalViewStillServes() async throws {
    let space = try makeSpace()
    let token = try await space.writeText("/gone.md", "here")
    let rev = Rev(token.rev!)
    try await space.fs(.shared).delete("/gone.md", ifMatch: nil)

    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).read("/gone.md") }
    #expect(try await space.readText("/gone.md", at: rev) == "here")
  }

  @Test func aHistoricalListingShowsExactlyTheDirectChildrenAtItsRevision() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a/x.md", "x")
    _ = try await space.writeText("/a/sub/deep.md", "deep")
    _ = try await space.writeText("/ab.md", "sibling")
    _ = try await space.writeText("/a0/z.md", "after the range")
    _ = try await space.writeText("/a-b/y.md", "before the range")
    let token = try await space.writeText("/a/gone.md", "gone")
    try await space.fs(.shared).delete("/a/gone.md", ifMatch: nil)
    _ = try await space.writeText("/a/later.md", "later")
    let rev = Rev(token.rev!)

    #expect(try await space.fs(.shared, at: rev).list("/a").1.map(\.name) == ["gone.md", "sub", "x.md"])
    let latest = Rev(try await space.fs(.shared).read("/a/later.md").0.rev!)
    #expect(try await space.fs(.shared, at: latest).list("/a").1.map(\.name) == ["later.md", "sub", "x.md"])
    #expect(try await space.fs(.shared, at: rev).list("/").1.map(\.name) == ["a", "a-b", "a0", "ab.md"])
    #expect(try await space.fs(.shared, at: rev).list("/a/sub").1.map(\.name) == ["deep.md"])
  }
}

@Suite struct TokenGatingTests {
  @Test func staleIfMatchFails() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/f.md", "one")
    _ = try await space.writeText("/f.md", "two")
    await #expect(throws: SpaceError.self) {
      _ = try await space.writeText("/f.md", "three", ifMatch: token1)
    }
  }

  @Test func currentIfMatchSucceeds() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/f.md", "one")
    let token2 = try await space.writeText("/f.md", "two", ifMatch: token1)
    #expect(token2.rev! > token1.rev!)
  }

  @Test func noChangeWriteMintsNoRevisionAndReturnsSameToken() async throws {
    let space = try makeSpace()
    let token1 = try await space.writeText("/same.md", "content")
    let revBefore = try await space.currentRevision()
    let token2 = try await space.writeText("/same.md", "content")
    let revAfter = try await space.currentRevision()

    #expect(token1 == token2)
    #expect(revBefore == revAfter)

    let token3 = try await space.writeText("/other.md", "x")
    #expect(token3.rev! == revBefore + 1)
  }
}

@Suite struct MoveTests {
  @Test func moveLeavesFileContentByteIdentical() async throws {
    let space = try makeSpace()
    let original = bytes("hello world\nsecond line")
    _ = try await space.fs(.shared).write("/a.md", original, ifMatch: nil)
    try await space.fs(.shared).move("/a.md", to: "/b.md")

    let moved = try await space.fs(.shared).read("/b.md").1
    #expect(moved == original)
    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).read("/a.md") }
  }

  @Test func moveDirectoryRelocatesSubtree() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/d/x.md", "ex")
    _ = try await space.writeText("/d/sub/y.md", "why")
    try await space.fs(.shared).move("/d", to: "/e")

    #expect(try await space.readText("/e/x.md") == "ex")
    #expect(try await space.readText("/e/sub/y.md") == "why")
    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).read("/d/x.md") }
  }
}
