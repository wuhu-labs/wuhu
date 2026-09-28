import Foundation
import JSONValue
import SpaceContract
import SpaceTools
import Testing

@Suite struct FsToolTests {
  @Test func rootListingHidesTheSystemFolderUnlessAsked() async throws {
    let context = try makeContext()
    _ = try await seedFile("/_/sessions/brave-fox/AGENTS.md", "mine", context)
    _ = try await seedFile("/users/x/avatar.png", "png", context)
    _ = try await seedFile("/notes/a.md", "x", context)
    _ = try await seedFile("/sessions/foo.md", "ordinary", context)

    let plain = try await run("ls", .object(["path": "/"]), context, as: ListOutput.self)
    #expect(plain.entries.map(\.name) == ["notes", "sessions"])
    let hidden = try await run("ls", .object(["path": "/", "hidden": true]), context, as: ListOutput.self)
    #expect(hidden.entries.map(\.name) == ["_", "notes", "sessions", "users"])
    let inside = try await run("ls", .object(["path": "/_/sessions"]), context, as: ListOutput.self)
    #expect(inside.entries.map(\.name) == ["brave-fox"], "only the root listing hides the folder")
  }

  @Test func writeReadRoundTrip() async throws {
    let context = try makeContext()
    let written = try await seedFile("/notes/a.md", "hello\nworld", context)
    let read = try await run("read", .object(["path": "/notes/a.md"]), context, as: ReadOutput.self)
    #expect(read.content == "hello\nworld")
    #expect(read.token == written.token)
    #expect(written.rev! > 0)
  }

  @Test func readSupportsLinesAndRev() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo\nthree", context)
    _ = try await seedFile("/a.md", "changed", context)

    let sliced = try await run(
      "read", .object(["path": "/a.md", "rev": .integer(first.rev!), "lines": "2-3"]), context, as: ReadOutput.self,
    )
    #expect(sliced.content == "two\nthree")

    let overshoot = try await run("read", .object(["path": "/a.md", "lines": "1-99"]), context, as: ReadOutput.self)
    #expect(overshoot.content == "changed")

    let bad = await failure("read", .object(["path": "/a.md", "lines": "3-1"]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = bad { true } else { false } }())
  }

  @Test func resolverAddressing() async throws {
    let context = try makeContext()
    // A context without a machine seam (client-side toolbox use) refuses
    // machines:// addresses instead of walking the space.
    let machines = await failure("read", .object(["path": "machines://mc_00000000/a.md"]), context)
    #expect({ if case .failed(code: .unavailable, _, _, _) = machines { true } else { false } }())

    let badID = await failure("read", .object(["path": "machines://not a machine/a.md"]), context)
    #expect({ if case .failed(code: .invalidPath, _, _, _) = badID { true } else { false } }())

    let atRev = await failure("read", .object(["path": "machines://mc_00000000/a.md@3"]), context)
    #expect({ if case .failed(code: .unsupported, _, _, _) = atRev { true } else { false } }())

    let wuhuHost = await failure("read", .object(["path": "wuhu://example.test/x.md"]), context)
    #expect({ if case let .failed(code: .invalidPath, message, _, _) = wuhuHost {
      message == "not a file address: wuhu://example.test/x.md; use /<path> for this group, wuhu://<group>.localspace/<path> for another group, machines://<machine>/<path> for a machine or wuhu://system/<path> for the system files"
    } else { false } }())
  }

  @Test func theSystemHostReadsSearchesAndRefusesWrites() async throws {
    let context = try makeContext()
    let read = try await run("read", .object(["path": "wuhu://system/AGENTS.md"]), context, as: ReadOutput.self)
    #expect(read.content.hasPrefix("# Working in a Wuhu space"))
    let listed = try await run("ls", .object(["path": "wuhu://system/skills"]), context, as: ListOutput.self)
    #expect(listed.entries.map(\.name).contains("read-box"))

    let found = try await run("find", .object(["glob": "**/SKILL.md", "path": "wuhu://system/"]), context, as: FindOutput.self)
    #expect(found.paths.contains("wuhu://system/skills/sessions/SKILL.md"))
    let grepped = try await run(
      "grep", .object(["pattern": "topLevel: true", "path": "wuhu://system/skills"]), context, as: GrepOutput.self,
    )
    #expect(grepped.matches.map(\.path).contains("wuhu://system/skills/sessions/SKILL.md"))

    for (name, input) in [
      ("write", JSONValue.object(["path": "wuhu://system/AGENTS.md", "content": "x"])),
      ("rm", .object(["path": "wuhu://system/AGENTS.md"])),
      ("mv", .object(["from": "wuhu://system/AGENTS.md", "to": "/AGENTS.md"])),
      ("mv", .object(["from": "/nope.md", "to": "wuhu://system/nope.md"])),
    ] {
      let refused = await failure(name, input, context)
      #expect({ if case .failed(code: .unsupported, _, _, _) = refused { true } else { false } }(), "\(name) \(input)")
    }
    let atRev = await failure("read", .object(["path": "wuhu://system/AGENTS.md@3"]), context)
    #expect(atRev != nil)

    // Nothing of the system files lands in the space.
    let root = try await run("ls", .object(["path": "/", "hidden": true]), context, as: ListOutput.self)
    #expect(root.entries.isEmpty)
    let docs = try await run("query", .object(["sql": "SELECT path FROM docs"]), context)
    #expect(!"\(docs)".contains("AGENTS"))
  }

  @Test func writeStaleTokenConflictsWithHint() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)

    let stale = await failure(
      "write", .object(["path": "/a.md", "content": "v3", "ifMatch": .string(first.token)]), context,
    )
    guard case let .failed(code, _, hint, _) = stale else {
      Issue.record("expected conflict, got \(String(describing: stale))")
      return
    }
    #expect(code == .conflict)
    #expect(hint == "changed since you read it — re-read")
  }

  @Test func editAppliesSequentially() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "alpha\nbeta\ngamma", context)
    let edited = try await run(
      "edit",
      .object(["path": "/a.md", "edits": .array([
        .object(["old": "beta", "new": "BETA"]),
        .object(["old": "gamma", "new": "GAMMA"]),
      ])]),
      context,
      as: EditOutput.self,
    )
    let read = try await run("read", .object(["path": "/a.md"]), context, as: ReadOutput.self)
    #expect(read.content == "alpha\nBETA\nGAMMA")
    #expect(read.token == edited.token)
  }

  @Test func editAmbiguousMatchHintCarriesLineNumbers() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "alpha\nbeta\nalpha", context)
    let ambiguous = await failure(
      "edit", .object(["path": "/a.md", "edits": .array([.object(["old": "alpha", "new": "x"])])]), context,
    )
    guard case let .failed(code, message, hint, _) = ambiguous else {
      Issue.record("expected conflict, got \(String(describing: ambiguous))")
      return
    }
    #expect(code == .conflict)
    #expect(message.contains("2 times"))
    #expect(hint?.contains("at lines 1, 3") == true)
  }

  @Test func editStaleIfMatchConflicts() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)
    let stale = await failure(
      "edit",
      .object(["path": "/a.md", "ifMatch": .string(first.token), "edits": .array([.object(["old": "v2", "new": "v3"])])]),
      context,
    )
    guard case let .failed(code, _, hint, _) = stale else {
      Issue.record("expected conflict, got \(String(describing: stale))")
      return
    }
    #expect(code == .conflict)
    #expect(hint == "changed since you read it — re-read")
  }

  @Test func syncSavesAgainstTheLoadedRevision() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo\n", context)
    let synced = try await run(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(first.token), "content": "ONE\ntwo\n"]),
      context,
      as: SyncOutput.self,
    )
    guard case let .saved(_, token, content) = synced else {
      Issue.record("expected saved, got \(synced)")
      return
    }
    #expect(content == "ONE\ntwo\n")
    #expect(token != first.token)
  }

  @Test func syncMergesNonoverlappingChanges() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo\nthree\n", context)
    _ = try await seedFile("/a.md", "ONE\ntwo\nthree\n", context)
    let synced = try await run(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(first.token), "content": "one\ntwo\nTHREE\n"]),
      context,
      as: SyncOutput.self,
    )
    guard case let .merged(_, _, content) = synced else {
      Issue.record("expected merged, got \(synced)")
      return
    }
    #expect(content == "ONE\ntwo\nTHREE\n")
    #expect(try await run("read", .object(["path": "/a.md"]), context, as: ReadOutput.self).content == content)
  }

  @Test func syncReturnsOverlappingChangesWithoutWriting() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo\n", context)
    let remote = try await seedFile("/a.md", "remote\ntwo\n", context)
    let synced = try await run(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(first.token), "content": "local\ntwo\n"]),
      context,
      as: SyncOutput.self,
    )
    #expect(synced == .conflict(token: remote.token, content: "remote\ntwo\n"))
    #expect(try await run("read", .object(["path": "/a.md"]), context, as: ReadOutput.self).content == "remote\ntwo\n")
  }

  @Test func syncDeduplicatesTheSameConcurrentChange() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo\n", context)
    let remote = try await seedFile("/a.md", "ONE\ntwo\n", context)
    let synced = try await run(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(first.token), "content": "ONE\ntwo\n"]),
      context,
      as: SyncOutput.self,
    )
    #expect(synced == .saved(rev: remote.rev!, token: remote.token, content: "ONE\ntwo\n"))
  }

  @Test func syncMergesInsertionsAtOppositeEnds() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "one\ntwo", context)
    _ = try await seedFile("/a.md", "zero\none\ntwo", context)
    let synced = try await run(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(first.token), "content": "one\ntwo\nthree"]),
      context,
      as: SyncOutput.self,
    )
    guard case let .merged(_, _, content) = synced else {
      Issue.record("expected merged, got \(synced)")
      return
    }
    #expect(content == "zero\none\ntwo\nthree")
  }

  @Test func syncRejectsATokenFromAnotherFile() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "one", context)
    let other = try await seedFile("/b.md", "two", context)
    let rejected = await failure(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(other.token), "content": "changed"]),
      context,
    )
    guard case let .failed(code, _, hint, _) = rejected else {
      Issue.record("expected conflict, got \(String(describing: rejected))")
      return
    }
    #expect(code == .conflict)
    #expect(hint == "re-read the document and retry")
  }

  @Test func rmReturnsRevisionAndDeletes() async throws {
    let context = try makeContext()
    let written = try await seedFile("/a.md", "x", context)
    let removed = try await run("rm", .object(["path": "/a.md"]), context, as: RevisionOutput.self)
    #expect(removed.rev > written.rev!)
    let gone = await failure("read", .object(["path": "/a.md"]), context)
    #expect({ if case .failed(code: .notFound, _, _, _) = gone { true } else { false } }())
  }

  @Test func mvReportsDanglingInboundLinks() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "see [b](/b.md)", context)
    _ = try await seedFile("/b.md", "target", context)

    let moved = try await run("mv", .object(["from": "/b.md", "to": "/c.md"]), context, as: MoveOutput.self)
    #expect(moved.dangling == ["/a.md"])

    let direct = try await run(
      "query", .object(["sql": "SELECT DISTINCT src FROM links WHERE dst = '/b.md' OR dst LIKE '/b.md/%' ORDER BY src"]),
      context, as: QueryOutput.self,
    )
    #expect(direct.rows.map(\.[0]) == moved.dangling.map(JSONValue.string))

    let read = try await run("read", .object(["path": "/c.md"]), context, as: ReadOutput.self)
    #expect(read.content == "target")
  }

  @Test func readSupportsAtRevAddresses() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)
    let old = try await run("read", .object(["path": .string("/a.md@\(first.rev!)")]), context, as: ReadOutput.self)
    #expect(old.content == "v1")
  }

  @Test func historicalReadsRejectUnknownRevisions() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "x", context)

    let viaField = await failure("read", .object(["path": "/a.md", "rev": 999]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = viaField { true } else { false } }())

    let viaAddress = await failure("read", .object(["path": "/a.md@999"]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = viaAddress { true } else { false } }())

    let viaLs = await failure("ls", .object(["path": "/", "rev": 999]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = viaLs { true } else { false } }())
  }

  @Test func checkoutOfNeverExistedPathIsNotFound() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "x", context)
    let missing = await failure("checkout", .object(["path": "/never.md", "rev": 1]), context)
    #expect({ if case .failed(code: .notFound, _, _, _) = missing { true } else { false } }())
  }

  @Test func rmRemovesDirectorySubtree() async throws {
    let context = try makeContext()
    _ = try await seedFile("/d/x.md", "x", context)
    _ = try await seedFile("/d/sub/y.md", "y", context)

    let removed = try await run("rm", .object(["path": "/d"]), context, as: RevisionOutput.self)
    #expect(removed.rev > 0)
    for gone in ["/d", "/d/x.md", "/d/sub/y.md"] {
      let missing = await failure("stat", .object(["path": .string(gone)]), context)
      #expect({ if case .failed(code: .notFound, _, _, _) = missing { true } else { false } }(), "\(gone)")
    }
  }

  @Test func mvRelocatesDirectorySubtree() async throws {
    let context = try makeContext()
    _ = try await seedFile("/d/x.md", "x", context)
    _ = try await seedFile("/link.md", "[l](/d/x.md)", context)

    let moved = try await run("mv", .object(["from": "/d", "to": "/e"]), context, as: MoveOutput.self)
    #expect(moved.dangling == ["/link.md"])
    let read = try await run("read", .object(["path": "/e/x.md"]), context, as: ReadOutput.self)
    #expect(read.content == "x")
  }

  @Test func mvDanglingScanDoesNotTreatUnderscoreAsWildcard() async throws {
    let context = try makeContext()
    _ = try await seedFile("/s1.md", "[l](/a_b.md)", context)
    _ = try await seedFile("/s2.md", "[l](/axb.md)", context)
    _ = try await seedFile("/a_b.md", "target", context)
    _ = try await seedFile("/axb.md", "decoy", context)

    let moved = try await run("mv", .object(["from": "/a_b.md", "to": "/c.md"]), context, as: MoveOutput.self)
    #expect(moved.dangling == ["/s1.md"])

    _ = try await seedFile("/s3.md", "[l](/a_b/inner.md)", context)
    _ = try await seedFile("/s4.md", "[l](/axb/inner.md)", context)
    _ = try await seedFile("/a_b/inner.md", "target", context)
    let subtree = try await run("mv", .object(["from": "/a_b", "to": "/moved"]), context, as: MoveOutput.self)
    #expect(subtree.dangling == ["/s3.md"])
  }

  @Test func mvRefusesAnExistingDestinationUnlessReplacing() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "new", context)
    _ = try await seedFile("/b.md", "old", context)
    let last = try await seedFile("/d/x.md", "x", context)

    let refused = await failure("mv", .object(["from": "/a.md", "to": "/b.md"]), context)
    #expect({ if case .failed(code: .conflict, _, _, _) = refused { true } else { false } }())

    let folder = await failure("mv", .object(["from": "/a.md", "to": "/d", "replace": true]), context)
    #expect({ if case .failed(code: .conflict, _, _, _) = folder { true } else { false } }())

    let moved = try await run("mv", .object(["from": "/a.md", "to": "/b.md", "replace": true]), context, as: MoveOutput.self)
    #expect(moved.rev == last.rev! + 1)
    let read = try await run("read", .object(["path": "/b.md"]), context, as: ReadOutput.self)
    #expect(read.content == "new")
    let gone = await failure("stat", .object(["path": "/a.md"]), context)
    #expect({ if case .failed(code: .notFound, _, _, _) = gone { true } else { false } }())
  }

  @Test func mvRejectsAtRevDestination() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "x", context)
    let rejected = await failure("mv", .object(["from": "/a.md", "to": "/b.md@3"]), context)
    #expect({ if case .failed(code: .invalidPath, _, _, _) = rejected { true } else { false } }())
    let intact = try await run("read", .object(["path": "/a.md"]), context, as: ReadOutput.self)
    #expect(intact.content == "x")
  }

  @Test func lsAndStatProjectEntries() async throws {
    let context = try makeContext()
    _ = try await seedFile("/notes/a.md", "one\ntwo", context)
    _ = try await seedFile("/notes/b.md", "x", context)

    let listed = try await run("ls", .object(["path": "/notes"]), context, as: ListOutput.self)
    #expect(listed.entries.map(\.name) == ["a.md", "b.md"])
    #expect(listed.entries.allSatisfy { $0.kind == .file })
    #expect(listed.entries[0].lineCount == 2)
    #expect(listed.entries[0].mtime == fixedDate.timeIntervalSince1970)

    let root = try await run("ls", .object(["path": "/"]), context, as: ListOutput.self)
    #expect(root.entries.map(\.name) == ["notes"])
    #expect(root.entries[0].kind == .directory)

    let stat = try await run("stat", .object(["path": "/notes/a.md"]), context, as: Entry.self)
    #expect(stat.name == "a.md")
    #expect(stat.size == "one\ntwo".utf8.count)
  }

  @Test func lsCarriesTheCommittedRev() async throws {
    let context = try makeContext()
    let first = try await seedFile("/notes/a.md", "one", context)
    let listed = try await run("ls", .object(["path": "/notes"]), context, as: ListOutput.self)
    #expect(listed.rev == first.rev)

    let second = try await seedFile("/notes/b.md", "two", context)
    let again = try await run("ls", .object(["path": "/notes"]), context, as: ListOutput.self)
    #expect(again.rev == second.rev)

    let pinned = try await run(
      "ls", .object(["path": "/notes", "rev": .integer(first.rev!)]), context, as: ListOutput.self,
    )
    #expect(pinned.rev == first.rev)
    #expect(pinned.entries.map(\.name) == ["a.md"])
  }

  @Test func lsRevIsConsistentWithTheListingUnderConcurrentWrites() async throws {
    let context = try makeContext()
    _ = try await seedFile("/race/seed.md", "x", context)
    let writes = Task {
      for index in 1 ... 30 {
        _ = try await seedFile("/race/f\(index).md", "content \(index)", context)
      }
    }
    for _ in 1 ... 10 {
      let listed = try await run("ls", .object(["path": "/race"]), context, as: ListOutput.self)
      let pinned = try await run(
        "ls", .object(["path": "/race", "rev": .integer(listed.rev!)]), context, as: ListOutput.self,
      )
      #expect(pinned.entries == listed.entries)
    }
    try await writes.value
  }
}
