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
    let liveToken = try await space.writeText("/doc.md", "v2")
    let stream = await space.observeFS(glob: "**", group: .shared).mutations
    var events = stream.makeAsyncIterator()
    let (rev, token) = try await space.checkout(path("/doc.md"), rev: rev1, in: .shared, acting: .shared, ifMatch: liveToken)

    #expect(rev.value == liveToken.rev! + 1)
    #expect(token == VersionToken(rev: rev.value))
    #expect(try await space.readText("/doc.md") == "v1")
    let entries = try await space.history(path("/doc.md"), in: .shared)
    #expect(entries.count == 3)
    #expect(entries.last?.0 == rev)
    #expect(entries.last?.2 == .checkout(fromRev: rev1.value))
    let event = await events.next()
    #expect(event?.path == "/doc.md")
    #expect(event?.rev == rev.value)
    #expect(event?.kind == .write)
    #expect(event?.entry == .file)
  }

  @Test(arguments: [false, true]) func noChangeCheckoutKeepsLiveTokenRevisionHistoryAndObservation(olderRevision: Bool) async throws {
    let space = try makeSpace()
    let first = try await space.writeText("/same.md", "content")
    var liveToken = first
    if olderRevision {
      _ = try await space.writeText("/same.md", "different")
      liveToken = try await space.writeText("/same.md", "content")
    }
    _ = try await space.writeText("/other.md", "unrelated")
    let revBefore = try await space.currentRevision()
    let historyBefore = try await space.history(path("/same.md"), in: .shared)
    let stream = await space.observeFS(glob: "**", group: .shared).mutations
    var events = stream.makeAsyncIterator()

    await #expect(throws: SpaceError.versionMismatch("/same.md")) {
      _ = try await space.checkout(path("/same.md"), rev: Rev(first.rev!), in: .shared, acting: .shared, ifMatch: VersionToken(rev: revBefore))
    }
    await #expect(throws: SpaceError.alreadyExists("/same.md")) {
      _ = try await space.checkout(path("/same.md"), rev: Rev(first.rev!), in: .shared, acting: .shared, createOnly: true)
    }
    let (rev, token) = try await space.checkout(path("/same.md"), rev: Rev(first.rev!), in: .shared, acting: .shared, ifMatch: liveToken)

    #expect(rev == Rev(liveToken.rev!))
    #expect(token == liveToken)
    #expect(try await space.currentRevision() == revBefore)
    let historyAfter = try await space.history(path("/same.md"), in: .shared)
    #expect(historyAfter.map(\.0) == historyBefore.map(\.0))
    #expect(historyAfter.map(\.2) == historyBefore.map(\.2))
    #expect(try await space.readText("/same.md") == "content")

    let sentinel = try await space.writeText("/sentinel.md", "sentinel")
    #expect(sentinel.rev == revBefore + 1)
    let event = await events.next()
    #expect(event?.path == "/sentinel.md")
    #expect(event?.rev == sentinel.rev)
    #expect(event?.kind == .write)
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

@Suite struct PagedListingTests {
  @Test func liveAndHistoricalListingsPageFromANameInNameOrder() async throws {
    let space = try makeSpace()
    for name in ["d/b.md", "d/a.md", "d/c", "d/c-1.md", "d/sub/x.md", "top.md"] {
      _ = try await space.writeText("/" + name, name)
    }
    let token = try await space.writeText("/d/z.md", "z")
    _ = try await space.writeText("/d/late.md", "late")
    let live = await space.fs(.shared)
    let then = await space.fs(.shared, at: Rev(try #require(token.rev)))

    for (fs, all) in [(live, ["a.md", "b.md", "c", "c-1.md", "late.md", "sub", "z.md"]), (then, ["a.md", "b.md", "c", "c-1.md", "sub", "z.md"])] {
      var names: [String] = []
      var from = ""
      var pages = 0
      while true {
        let (entries, next) = try await fs.list("/d", from: from, limit: 2)
        #expect(entries.count <= 2)
        names += entries.map(\.name)
        pages += 1
        guard let next else { break }
        from = next
      }
      #expect(names == all)
      #expect(pages == (all.count + 1) / 2)
      let tail = try await fs.list("/d", from: "c-", limit: 10)
      #expect(tail.entries.map(\.name) == all.filter { $0 >= "c-" })
      #expect(tail.next == nil)
      #expect(try await fs.list("/", from: "d", limit: 1).entries.map(\.name) == ["d"])
    }
  }
}
