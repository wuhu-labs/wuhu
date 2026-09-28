import Foundation
import GRDB
import JSONValue
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct GroupIsolationTests {
  static let alice = GroupID(rawValue: "alice")
  static let bob = GroupID(rawValue: "bob")

  // alice reads shared; bob reads nothing. alice holds /plan.md, /t.table and
  // a session; shared holds /readme.md.
  func seeded() async throws -> Space {
    let space = try makeSpace()
    try await space.writer.write { db in
      for group in [Self.alice, Self.bob] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00.000Z')", arguments: [group.rawValue])
      }
    }
    try await space.addEdge(src: Self.alice, dst: .shared, kind: .read, by: nil)
    try await space.addEdge(src: Self.bob, dst: Self.bob, kind: .read, by: nil)
    _ = try await space.fs(Self.alice).write("/plan.md", bytes("# Plan\n\nSee [readme](wuhu://shared.localspace/readme.md).\n"), ifMatch: nil)
    _ = try await space.fs(.shared).write("/readme.md", bytes("# Readme\n"), ifMatch: nil)
    _ = try await space.createTable(path("/t.table"), header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: Self.alice, acting: Self.alice)
    _ = try await space.mutateRows(path("/t.table"), [.insert([.integer(7)])], in: Self.alice, acting: Self.alice)
    _ = try await space.sessions.createSession(group: Self.alice, title: "a", kind: .agent, createdBy: "owner", model: .test)
    return space
  }

  func rows(_ space: Space, _ group: GroupID, _ sql: String) async throws -> [[Cell]] {
    try await space.query(sql, as: Principal(actor: .anonymous, group: group)).rows
  }

  func refusal(_ space: Space, _ group: GroupID, _ sql: String) async -> SpaceError? {
    do {
      _ = try await space.query(sql, as: Principal(actor: .anonymous, group: group))
      return nil
    } catch {
      return error as? SpaceError
    }
  }

  @Test func sharedSeesNoneOfAlicesData() async throws {
    let space = try await seeded()
    #expect(try await rows(space, .shared, "SELECT * FROM docs WHERE path = '/plan.md'").isEmpty)
    #expect(try await rows(space, .shared, "SELECT title FROM sessions") == [])
    #expect(await refusal(space, .shared, "SELECT * FROM \"/t.table\"") == .unknownRelation("/t.table"))
    #expect(await refusal(space, .shared, "SELECT * FROM \"wuhu://alice.localspace/docs\"") == .unknownRelation("wuhu://alice.localspace/docs"))
    #expect(await refusal(space, .shared, "SELECT * FROM \"wuhu://nobody.localspace/docs\"") == .unknownRelation("wuhu://nobody.localspace/docs"))
    #expect(await refusal(space, .shared, "SELECT * FROM \"alice:/t.table\"") == .queryForbiddenTable("alice:/t.table"))
  }

  @Test func aliceReadsHerOwnAndSharedButNeverUnqualified() async throws {
    let space = try await seeded()
    #expect(try await rows(space, Self.alice, "SELECT path FROM docs") == [[.text("/plan.md")]])
    #expect(try await rows(space, Self.alice, "SELECT n FROM \"/t.table\"") == [[.integer(7)]])
    #expect(try await rows(space, Self.alice, "SELECT path, title FROM \"wuhu://shared.localspace/docs\"") == [[.text("/readme.md"), .text("readme.md")]])
    #expect(try await rows(space, Self.alice, "SELECT grp, path FROM \"wuhu://*.localspace/docs\" ORDER BY grp") == [
      [.text("alice"), .text("/plan.md")], [.text("shared"), .text("/readme.md")],
    ])
    #expect(try await rows(space, Self.alice, "SELECT * FROM links") == [])
    #expect(try await rows(space, Self.alice, "SELECT src, dst_grp, dst FROM \"wuhu://alice.localspace/links\"") == [
      [.text("/plan.md"), .text("shared"), .text("/readme.md")],
    ])
    #expect(try await rows(space, Self.alice, "SELECT readable, via FROM group_reads ORDER BY readable") == [
      [.text("alice"), .text("self")], [.text("shared"), .text("alice->shared")],
    ])
  }

  @Test func aStreamCarriesOnlyItsGroup() async throws {
    let space = try await seeded()
    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }
    _ = try await space.fs(Self.alice).write("/late.md", bytes("alice"), ifMatch: nil)
    _ = try await space.fs(.shared).write("/after.md", bytes("shared"), ifMatch: nil)
    let collected = await awaitItems(events, atLeast: 2)
    await settle()
    #expect(collected.map(\.path) == ["/readme.md", "/after.md"])
    #expect(collected.allSatisfy { $0.group == .shared })
  }

  @Test func aCrossGroupMoveIsOneRevisionLeavingOneGroupForTheOther() async throws {
    let space = try await seeded()
    let (left, arrived) = (Collector<MutationEvent>(), Collector<MutationEvent>())
    let fromShared = await space.observeFS(glob: "**", group: .shared)
    let intoAlice = await space.observeFS(glob: "**", group: Self.alice)
    let consumers = [
      Task { for await event in fromShared { await left.append(event) } },
      Task { for await event in intoAlice { await arrived.append(event) } },
    ]
    defer { consumers.forEach { $0.cancel() } }
    try await space.move("/readme.md", in: .shared, to: "/docs/readme.md", in: Self.alice, replacing: false, acting: Self.alice)
    let deleted = await awaitItems(left, atLeast: 1)
    let written = await awaitItems(arrived, atLeast: 1)
    await settle()
    #expect(deleted.map(\.kind) == [.delete] && deleted.map(\.path) == ["/readme.md"])
    #expect(written.map(\.path).last == "/docs/readme.md" && written.last?.kind == .write)
    #expect(Set((deleted + written).map(\.rev)).count == 1)
    #expect(try await space.fs(Self.alice).read("/docs/readme.md").1 == bytes("# Readme\n"))
    #expect((try? await space.fs(.shared).read("/readme.md")) == nil)
    #expect(try await space.history(path("/readme.md"), in: .shared).last?.2 == .delete)
    #expect(try await space.history(path("/docs/readme.md"), in: Self.alice).count == 1)
    let minted = try #require(deleted.first?.rev)
    let acting = try await space.writer.read { db in try String.fetchOne(db, sql: "SELECT grp FROM revisions WHERE rev = ?", arguments: [minted]) }
    #expect(acting == "alice")
  }

  @Test func aTableMovedAcrossGroupsTakesItsRows() async throws {
    let space = try await seeded()
    try await space.move("/t.table", in: Self.alice, to: "/t.table", in: .shared, replacing: false, acting: Self.alice)
    #expect(try await rows(space, .shared, "SELECT n FROM \"/t.table\"") == [[.integer(7)]])
    #expect(await refusal(space, Self.alice, "SELECT * FROM \"/t.table\"") == .unknownRelation("/t.table"))
    _ = try await space.mutateRows(path("/t.table"), [.insert([.integer(8)])], in: .shared, acting: .shared)
    #expect(try await rows(space, .shared, "SELECT n FROM \"/t.table\" ORDER BY n") == [[.integer(7)], [.integer(8)]])
  }

  @Test func bobReachesNothingOfAlices() async throws {
    let space = try await seeded()
    #expect(try await rows(space, Self.bob, "SELECT * FROM docs").isEmpty)
    #expect(try await rows(space, Self.bob, "SELECT * FROM sessions").isEmpty)
    #expect(await refusal(space, Self.bob, "SELECT * FROM \"/t.table\"") == .unknownRelation("/t.table"))
    #expect(await refusal(space, Self.bob, "SELECT * FROM \"wuhu://alice.localspace/t.table\"") == .unknownRelation("wuhu://alice.localspace/t.table"))
    #expect(await refusal(space, Self.bob, "SELECT * FROM \"wuhu://alice.localspace/docs\"") == .unknownRelation("wuhu://alice.localspace/docs"))
    #expect(await refusal(space, Self.bob, "SELECT * FROM \"wuhu://shared.localspace/docs\"") == .unknownRelation("wuhu://shared.localspace/docs"))
    #expect(try await rows(space, Self.bob, "SELECT DISTINCT grp FROM \"wuhu://*.localspace/docs\"").isEmpty)
    #expect(await refusal(space, Self.bob, "SELECT * FROM \"alice:/t.table\"") == .queryForbiddenTable("alice:/t.table"))
  }

  @Test func removingTheReadEdgeEndsAnOpenObservation() async throws {
    let space = try await seeded()
    let stream = await space.observeQuery(
      "SELECT path FROM \"wuhu://shared.localspace/docs\"", throttle: .zero, as: Principal(actor: .anonymous, group: Self.alice),
    )
    let frames = Collector<Rows>()
    let ending = Task { () -> (any Error)? in
      do {
        for try await rows in stream { await frames.append(rows) }
        return nil
      } catch {
        return error
      }
    }
    #expect(await awaitItems(frames, atLeast: 1).map(\.rows) == [[[.text("/readme.md")]]])
    try await space.removeEdge(src: Self.alice, dst: .shared, kind: .read)
    let error = await ending.value
    #expect(error as? SpaceError == .unknownRelation("wuhu://shared.localspace/docs"))
  }

  @Test func aRowWithoutAGroupIsRefused() async throws {
    let space = try makeSpace()
    for table in ["sessions", "revisions", "conversations", "notifications", "machines", "machine_execs", "script_execs", "join_tokens"] {
      await #expect {
        try await space.writer.write { db in try db.execute(sql: "INSERT INTO \(table) DEFAULT VALUES") }
      } throws: { error in
        (error as? DatabaseError)?.message == "grp required: \(table)"
      }
    }
  }
}

@Suite struct GroupAdminTests {
  @Test func topLevelAgentsAdministerTheirGroupAndNothingElseDoes() async throws {
    let space = try makeSpace()
    let store = space.sessions
    let agent = try await store.createSession(group: .shared, title: "S", kind: .agent, createdBy: "owner", model: .test)
    let task = try await store.createSession(
      group: .shared, title: "St", kind: .task, parent: agent, createdBy: "owner", executor: .kernel(.test),
    )
    let child = try await store.createSession(
      group: .shared, title: "Sc", kind: .agent, parent: agent, createdBy: "owner", executor: .kernel(.test),
    )
    #expect(try await space.isAdmin(.session(agent), of: .shared))
    #expect(try await !space.isAdmin(.session(task), of: .shared))
    #expect(try await !space.isAdmin(.session(child), of: .shared))
    #expect(try await !space.isAdmin(.session(agent), of: GroupID(rawValue: "elsewhere")))
    #expect(try await !space.isAdmin(.anonymous, of: .shared))
  }

  @Test func aPersonAdministersTheirOwnGroupAndSharedOnlyByEdge() async throws {
    let space = try makeSpace()
    let morgan = try await space.addAccount(kind: .human, name: "morgan", admin: true)
    let alice = try await space.addAccount(kind: .human, name: "alice")
    let alicesGroup = try #require(try await space.personalGroup(of: alice.id))
    #expect(try await space.isHumanAdmin(morgan.id, of: .shared))
    #expect(try await !space.isHumanAdmin(alice.id, of: .shared))
    #expect(try await space.isHumanAdmin(alice.id, of: alicesGroup))
    #expect(try await space.reads(alicesGroup) == [alicesGroup, .shared])
    #expect(try await Dictionary(uniqueKeysWithValues: space.accounts().map { ($0.name, $0.isAdmin) }) == ["morgan": true, "alice": false])

    _ = try await space.setAdmin(alice.id, admin: true)
    #expect(try await space.isHumanAdmin(alice.id, of: .shared))
    try await space.removeEdge(src: alicesGroup, dst: .shared, kind: .admin)
    #expect(try await !space.isHumanAdmin(alice.id, of: .shared))
    await #expect(throws: SpaceError.lastAdmin(morgan.id.rawValue)) { try await space.setAdmin(morgan.id, admin: false) }
    let morgansGroup = try #require(try await space.personalGroup(of: morgan.id))
    await #expect(throws: SpaceError.lastAdmin(morgansGroup.rawValue)) {
      try await space.removeEdge(src: morgansGroup, dst: .shared, kind: .admin)
    }
    #expect(try await space.isHumanAdmin(morgan.id, of: .shared))
    await #expect(throws: SpaceError.personalGroupEdge(alicesGroup.rawValue)) {
      try await space.removeEdge(src: alicesGroup, dst: alicesGroup, kind: .admin)
    }
    await #expect(throws: SpaceError.notAPerson("bot")) { try await space.addAccount(kind: .contractor, name: "bot", admin: true) }
    _ = try await space.removeAccount(alice.id)
    #expect(try await !space.isHumanAdmin(alice.id, of: alicesGroup))
  }

  // A team group that administers itself and shared makes its members human
  // admins of both, for isHumanAdmin, is_admin and last-admin counting alike.
  @Test func aTeamGroupsAdminEdgeCountsForItsMembersByTheOneRule() async throws {
    let space = try makeSpace()
    let morgan = try await space.addAccount(kind: .human, name: "morgan", admin: true)
    let carol = try await space.addAccount(kind: .human, name: "carol")
    let carolsGroup = try #require(try await space.personalGroup(of: carol.id))
    let ops = GroupID(rawValue: "ops")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('ops', '2099-01-01T00:00:00.000Z')")
      try db.execute(
        sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('ops', ?, '2099-01-01T00:00:00.000Z')",
        arguments: [carol.id.rawValue],
      )
    }
    try await space.addEdge(src: ops, dst: ops, kind: .admin, by: nil)
    try await space.addEdge(src: ops, dst: .shared, kind: .admin, by: nil)
    #expect(try await space.personalGroup(of: carol.id) == carolsGroup)
    #expect(try await space.isHumanAdmin(carol.id, of: .shared))
    #expect(try await space.isHumanAdmin(carol.id, of: ops))
    #expect(try await space.isAdmin(.person(persona: carolsGroup.rawValue, account: carol.id), of: .shared))
    #expect(try await Dictionary(uniqueKeysWithValues: space.accounts().map { ($0.name, $0.isAdmin) }) == ["morgan": true, "carol": true])

    // Revoking admin held through ops says so and changes nothing, even with
    // a personal edge to drop alongside it.
    _ = try await space.setAdmin(carol.id, admin: true)
    await #expect(throws: SpaceError.adminThroughGroup(account: carol.id.rawValue, groups: [ops.rawValue])) {
      try await space.setAdmin(carol.id, admin: false)
    }
    let kept = try await space.writer.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM group_edges WHERE src = ? AND dst = 'shared' AND kind = 'admin')",
        arguments: [carolsGroup.rawValue],
      )
    }
    #expect(kept == true)
    try await space.removeEdge(src: carolsGroup, dst: .shared, kind: .admin)
    await #expect(throws: SpaceError.adminThroughGroup(account: carol.id.rawValue, groups: [ops.rawValue])) {
      try await space.setAdmin(carol.id, admin: false)
    }
    #expect(try await space.isHumanAdmin(carol.id, of: .shared))

    _ = try await space.setAdmin(morgan.id, admin: false)
    #expect(try await !space.isHumanAdmin(morgan.id, of: .shared))
    await #expect(throws: SpaceError.lastAdmin(ops.rawValue)) {
      try await space.removeEdge(src: ops, dst: .shared, kind: .admin)
    }
    #expect(try await space.isHumanAdmin(carol.id, of: .shared))
  }

  @Test func theFirstPersonaNamesThePersonalGroup() async throws {
    let space = try makeSpace()
    let account = try await space.addAccount(kind: .human, name: nil)
    let group = try #require(try await space.personalGroup(of: account.id))
    let key = try await space.addKey(testPubkey("laptop"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let persona = try await space.adoptPersona(key: key)
    #expect(persona.name == group.rawValue)
    #expect(try await Set(space.groups().map(\.id)) == [.shared, group])
  }
}

// Every statement keyed on a path names its group: a path alone matches that
// path in every group.
@Suite struct StorageLintTests {
  static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources")

  @Test func noStatementKeysOnAPathAlone() throws {
    let pathKeyed: [Regex<Substring>] = [
      /ON CONFLICT\s*\([^)]*\bpath\b/,
      /\b(?:WHERE|AND|ON)\s+(?:\w+\.)?path\s*(?:=|LIKE|IN)/,
      /\$0\.(?:path|parentPath)\.(?:eq|in|like|glob)\(/,
    ]
    var offenders: [String] = []
    let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty)
    for file in files {
      for (number, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where pathKeyed.contains(where: { line.contains($0) }) && !line.contains("grp")
      {
        offenders.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
    #expect(offenders == [])
  }
}
