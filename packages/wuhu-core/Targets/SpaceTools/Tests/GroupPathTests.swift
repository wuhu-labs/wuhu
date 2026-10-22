import Clocks
import DeterministicDependencies
import JSONValue
import SpaceContract
@testable import SpaceCore
import SpaceTools
import Testing

// Alice's group reads shared; shared reads nothing of hers.
@Suite(.deterministicDependencies(clock: TestClock())) struct GroupPathTests {
  struct Rig {
    let shared: SpaceToolContext
    let alice: SpaceToolContext
    let group: GroupID

    var qualified: String { "wuhu://\(group.rawValue).localspace" }
  }

  func rig() async throws -> Rig {
    let base = try makeContext()
    let account = try await base.space.addAccount(kind: .human, name: "alice")
    let group = GroupID(rawValue: "alice")
    try await base.space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00Z')")
    }
    try await base.space.setGrant(.account, account.id.rawValue, role: .admin, in: group, by: .anonymous, acting: group)
    let alice = SpaceToolContext(space: base.space, principal: Principal(actor: .person(persona: group.rawValue, account: account.id), group: group))
    return Rig(shared: base, alice: alice, group: group)
  }

  func notFound(_ name: String, _ input: JSONValue, _ context: SpaceToolContext) async -> Bool {
    if case .failed(code: .notFound, _, _, _) = await failure(name, input, context) { true } else { false }
  }

  @Test func watchesResolveCurrentAndRetiredGroupAliasesBeforeCheckingAccess() async throws {
    let r = try await rig()
    try await r.alice.space.renameGroup(r.group, alias: "studio", by: r.alice.principal)
    let glob = "wuhu://studio.localspace/**/*.md"
    let watch = try await WatchedGlob(glob, as: r.alice.principal, in: r.alice.space)
    #expect(watch.group == r.group)
    #expect(watch.pattern == "/**/*.md")
    try await r.alice.space.renameGroup(r.group, alias: "notes", by: r.alice.principal)
    #expect(try await WatchedGlob(glob, as: r.alice.principal, in: r.alice.space).group == r.group)
    await #expect(throws: SpaceError.notFound(glob)) {
      try await WatchedGlob(glob, as: r.shared.principal, in: r.shared.space)
    }
  }

  @Test func sharedFindsNothingOfAlicesFiles() async throws {
    let rig = try await rig()
    let written = try await seedFile("/plan.md", "the secret plan", rig.alice)
    #expect(await notFound("read", ["path": "/plan.md"], rig.shared))
    #expect(await notFound("read", ["path": .string("\(rig.qualified)/plan.md")], rig.shared))
    #expect(await notFound("history", ["path": .string("\(rig.qualified)/plan.md")], rig.shared))
    let found = try await run("find", ["glob": "**"], rig.shared, as: FindOutput.self)
    #expect(!found.paths.contains("/plan.md"))
    let grep = try await run("grep", ["pattern": "secret"], rig.shared, as: GrepOutput.self)
    #expect(grep.matches.isEmpty)
    let history = try await run("history", ["path": "/plan.md"], rig.shared, as: HistoryOutput.self)
    #expect(history.entries.isEmpty)

    _ = try? await run("checkout", ["path": "/plan.md", "rev": .integer(written.rev!)], rig.shared)
    let kept = try await run("read", ["path": "/plan.md"], rig.alice, as: ReadOutput.self)
    #expect(kept.content == "the secret plan")
    #expect(await notFound("read", ["path": "/plan.md"], rig.shared))
  }

  @Test func aliceReachesSharedOnlyByItsQualifiedForm() async throws {
    let rig = try await rig()
    _ = try await seedFile("/AGENTS.md", "space manual", rig.shared)
    #expect(await notFound("read", ["path": "/AGENTS.md"], rig.alice))
    let read = try await run("read", ["path": "wuhu://shared.localspace/AGENTS.md"], rig.alice, as: ReadOutput.self)
    #expect(read.content == "space manual")

    _ = try await seedFile("wuhu://shared.localspace/notes/x.md", "from alice", rig.alice)
    let landed = try await run("read", ["path": "/notes/x.md"], rig.shared, as: ReadOutput.self)
    #expect(landed.content == "from alice")
    let found = try await run("find", ["glob": "**", "path": "wuhu://shared.localspace/notes"], rig.alice, as: FindOutput.self)
    #expect(found.paths == ["wuhu://shared.localspace/notes/x.md"])
  }

  @Test func aCrossGroupMoveLeavesOneGroupForTheOther() async throws {
    let rig = try await rig()
    _ = try await seedFile("/draft.md", "draft", rig.alice)
    let moved = try await run("mv", ["from": "/draft.md", "to": "wuhu://shared.localspace/published.md"], rig.alice, as: MoveOutput.self)
    #expect(moved.rev != nil)
    #expect(await notFound("read", ["path": "/draft.md"], rig.alice))
    let published = try await run("read", ["path": "/published.md"], rig.shared, as: ReadOutput.self)
    #expect(published.content == "draft")
    #expect(await notFound("mv", ["from": "/published.md", "to": .string("\(rig.qualified)/stolen.md")], rig.shared))
  }

  @Test func aRevisionedPathIsRefusedWhereOnlyTheCurrentOneMeansAnything() async throws {
    let rig = try await rig()
    let written = try await seedFile("/t.md", "x", rig.shared)
    let at = "/t.md@\(written.rev!)"
    let qualifiedAt = "wuhu://shared.localspace/t.md@\(written.rev!)"
    let inputs: [(String, JSONValue)] = [
      ("history", ["path": .string(at)]),
      ("history", ["path": .string(qualifiedAt)]),
      ("checkout", ["path": .string(at), "rev": .integer(written.rev!)]),
      ("table.create", ["path": "/n.table@1", "header": ["columns": [["name": "a", "type": "string"]]]]),
      ("table.alter", ["path": "/n.table@1", "ifMatch": "1", "header": ["columns": [["name": "a", "type": "string"]]]]),
      ("table.mutate", ["path": "/n.table@1", "ops": []]),
      ("new", ["template": .string(at)]),
      ("new", ["template": "/t.md", "in": "/dir@1"]),
    ]
    for (name, input) in inputs {
      let failure = await failure(name, input, rig.shared)
      #expect({ if case .failed(code: .invalidPath, _, _, _) = failure { true } else { false } }(), "\(name) \(input): \(String(describing: failure))")
    }
  }
}
