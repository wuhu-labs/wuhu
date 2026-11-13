import DeterministicDependencies
import LoopCore
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import class MainHub.Hub
import SessionDomain
@testable import SessionTools
import SpaceContract
@testable import SpaceServer
@_spi(Testing) @testable import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

private func creating(_ loop: ToolFixture) async throws -> ToolExecutor {
  try await loop.executor(owner: loop.hub { Hub(space: loop.space, resolveModelExecutor: { provider, model, effort in
    .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
  }) })
}

private func created(_ payload: ToolResultPayload) throws -> CreateSessionResult {
  guard case let .createSession(result) = payload else {
    throw Mismatch("expected a create outcome, got \(payload)")
  }
  return result
}

// The messages a session holds in its DMs with other sessions.
private func directMessages(_ space: Space, to session: SessionID) async throws -> [MessageRecord] {
  var found: [MessageRecord] = []
  for conversation in space.sessions.conversations(member: session.rawValue) where conversation.kind == .dmSession {
    found += try await space.sessions.messages(conversation: conversation.id)
  }
  return found
}

@Suite(.deterministicDependencies)
struct SessionTreeToolTests {
  @Test func topLevelCreationResolvesCurrentAndRetiredGroupAliases() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let account = try await space.addAccount(kind: .human, name: "Morgan")
      let group = try await space.createGroup(alias: "research", owner: account.id)
      try await space.setGrant(.group, "shared", role: .admin, in: group, by: (try await space.ensureDevPerson()).actor, acting: group)
      try await space.renameGroup(group, alias: "science", by: .shared(try await space.ensureDevPerson().actor))
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)
      for spelling in ["research", "science", group.rawValue] {
        let outcome = try created(try await world.run("create_session", .object([
          "title": "worker", "kind": "agent", "top_level": true, "group": .string(spelling),
        ])))
        #expect(try await space.sessions.record(outcome.sessionID).group == group)
      }
    }
  }

  @Test func createSessionRejectsAnUnknownExecutorAsTypedFailure() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)
      func refused(_ arguments: JSONValue) async throws -> ToolFailure {
        guard case let .failure(error) = try await world.run("create_session", ToolArguments(arguments)) else {
          throw Mismatch("an unknown executor created a session")
        }
        return error
      }
      let direct = try await refused(.object(["title": "removed", "executor": "claude-code"]))
      #expect(direct.code == "invalidArgument")
      #expect(direct.message == "create_session: unknown executor: claude-code")
      _ = try await space.fs(.shared).write("/templates/legacy/template.json", Data(#"{"executor":"claude-code","provider":"p","model":"m"}"#.utf8), ifMatch: nil)
      let templated = try await refused(.object(["title": "removed", "template": "legacy"]))
      #expect(templated.code == "invalidArgument")
      #expect(templated.message == "create_session: template legacy: unknown executor: claude-code")
    }
  }

  @Test func anAgentChildHasABoxAndAnswersItsParentsRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)

      let child = try created(try await world.run("create_session", .object([
        "title": "researcher", "kind": "agent", "expects_reply": .bool(true), "message": "look into it",
      ])))
      let record = try await space.sessions.record(child.sessionID)
      #expect(record.kind == .agent)
      #expect(record.parent == parent)
      #expect(try await space.sessions.conversation(ConversationID(child.sessionID.rawValue)).kind == .box)
      let request = try #require(child.requestID)
      _ = try await space.sessions.drainQueue(child.sessionID)

      var childWorld = ToolWorld(executor: try await creating(loop), session: child.sessionID)
      let report = try await childWorld.run("report", .object([
        "request_id": .string(request.rawValue), "kind": "final", "content": "found it",
      ]))
      guard case .report = report else { throw Mismatch("expected a report, got \(report)") }
    }
  }

  @Test func aSchemaGuardsARequestsFinal() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)
      let brief: ToolArguments = .object([
        "title": "reviewer", "expects_reply": .bool(true), "message": "review #7",
        "request": .object([
          "fields": .object(["pr": .number(7)]),
          "schema": .object(["type": "object", "required": .array(["verdict"])]),
        ]),
      ])
      let first = try created(try await world.run("create_session", brief))
      let request = try #require(first.requestID)
      _ = try await space.sessions.drainQueue(first.sessionID)
      var child = ToolWorld(executor: try await creating(loop), session: first.sessionID)
      let refused = try await child.run("report", .object(["request_id": .string(request.rawValue), "kind": "final", "content": "lgtm"]))
      #expect(try failureMessage(refused).contains("2 more refusals fail the request"))
      let report = try await child.run("report", .object([
        "request_id": .string(request.rawValue), "kind": "final", "content": #"{"verdict":"pass"}"#,
      ]))
      guard case .report = report else { throw Mismatch("expected a report, got \(report)") }
      let rows = try await space.query("SELECT status, result, fields FROM requests", as: .shared(.publicReader)).rows
      #expect(rows == [[.text("done"), .text(#"{"verdict":"pass"}"#), .text(#"{"pr":7}"#)]])
    }
  }

  @Test func anAgentTemplateMakesAnAgentAndAnExplicitKindWins() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      _ = try await space.fs(.shared).write("/templates/scribe/template.json", Data(#"{"kind":"agent"}"#.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/templates/scribe/AGENTS.md", Data("take notes".utf8), ifMatch: nil)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)

      let scribe = try created(try await world.run("create_session", .object(["title": "scribe", "template": "scribe"])))
      #expect(try await space.sessions.record(scribe.sessionID).kind == .agent)
      #expect(try await space.fs(.shared).read(SessionHome.path(of: scribe.sessionID) + "/AGENTS.md").1 == Data("take notes".utf8))

      let task = try created(try await world.run("create_session", .object([
        "title": "scribe task", "template": "scribe", "kind": "task",
      ])))
      #expect(try await space.sessions.record(task.sessionID).kind == .task)

      let odd = try await world.run("create_session", .object(["title": "x", "kind": "robot"]))
      #expect(try failureMessage(odd).contains("kind is task or agent"))
    }
  }

  @Test func aTopLevelAgentHasNoParentAndItsBriefArrivesAsADM() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let researcher = try await makeSession(space, name: "researcher")
      var world = ToolWorld(executor: try await creating(loop), session: researcher)

      let infra = try created(try await world.run("create_session", .object([
        "title": "Wuhu Infra", "top_level": .bool(true), "message": "your brief",
      ])))
      let record = try await space.sessions.record(infra.sessionID)
      #expect(record.kind == .agent)
      #expect(record.parent == nil)
      #expect(record.createdBy == researcher.rawValue)
      #expect(infra.requestID == nil)
      let brief = try #require(try await directMessages(space, to: infra.sessionID).first)
      #expect(brief.senderSession == researcher)
      #expect(brief.kind == .message)
      #expect(brief.content.text == "your brief")

      await #expect(throws: SessionStoreError.notInCharge(infra.sessionID.rawValue, actor: researcher.rawValue)) {
        try await space.sessions.refuseControl(of: infra.sessionID, by: researcher)
      }

      let reply = try await world.run("create_session", .object([
        "title": "x", "top_level": .bool(true), "expects_reply": .bool(true), "message": "m",
      ]))
      #expect(try failureMessage(reply).contains("no parent to report to"))
      let task = try await world.run("create_session", .object(["title": "x", "top_level": .bool(true), "kind": "task"]))
      #expect(try failureMessage(task).contains("a top-level session is an agent"))

      let worker = try created(try await world.run("create_session", .object(["title": "worker"])))
      var workerWorld = ToolWorld(executor: try await creating(loop), session: worker.sessionID)
      let fromTask = try await workerWorld.run("create_session", .object(["title": "x", "top_level": .bool(true)]))
      #expect(try failureMessage(fromTask).contains("only an agent may create a top-level session"))
    }
  }

  @Test func aChildTakesItsCreatorsGroupAndOnlyATopLevelAgentNamesOne() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let alice = try await plainGroup(space, "alice")
      let bob = try await plainGroup(space, "bob")
      // A session places a top-level agent outside its group only where its
      // group administers; shared is open but alice writes there, not admin.
      try await space.setGrant(.group, alice.rawValue, role: .admin, in: .shared, by: (try await space.ensureDevPerson()).actor, acting: .shared)
      let agent = try await makeSession(space, name: "agent", group: alice)
      var world = ToolWorld(executor: try await creating(loop), session: agent)

      let child = try created(try await world.run("create_session", .object(["title": "child"])))
      #expect(try await space.sessions.record(child.sessionID).group == alice)
      let named = try await world.run("create_session", .object(["title": "x", "group": "shared"]))
      #expect(try failureMessage(named).contains("only a top-level agent takes group"))

      let own = try created(try await world.run("create_session", .object(["title": "own", "top_level": .bool(true)])))
      #expect(try await space.sessions.record(own.sessionID).group == alice)
      let shared = try created(try await world.run(
        "create_session", .object(["title": "shared", "top_level": .bool(true), "group": "shared"]),
      ))
      #expect(try await space.sessions.record(shared.sessionID).group == .shared)
      let foreign = try await world.run(
        "create_session", .object(["title": "x", "top_level": .bool(true), "group": .string(bob.rawValue)]),
      )
      #expect(try failureMessage(foreign).contains("groupForbidden"))
    }
  }

  @Test func aMessageWithoutARequestReachesTheChildAsADM() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: try await creating(loop), session: parent)

      let first = try created(try await world.run(
        "create_session", .object(["title": "  primed  ", "message": "context for a human"]), id: "call-1",
      ))
      #expect(first.title == "primed")
      #expect(try await space.sessions.record(first.sessionID).title == "primed")
      let messages = try await directMessages(space, to: first.sessionID)
      #expect(messages.map(\.content.text) == ["context for a human"])
      #expect(messages.map(\.kind) == [.message])

      let twoLines = try await world.run("create_session", .object(["title": "two\nlines"]))
      #expect(try failureMessage(twoLines).contains("one non-empty line"))
    }
  }

  @Test func aSessionBelowLevelSixteenIsRefused() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      var level = try await makeSession(space, name: "root")
      for depth in 2 ... SessionStore.depthLimit {
        var world = ToolWorld(executor: try await creating(loop), session: level)
        level = try created(try await world.run("create_session", .object(["title": .string("level \(depth)")]))).sessionID
      }
      var deepest = ToolWorld(executor: try await creating(loop), session: level)
      let refused = try await deepest.run("create_session", .object(["title": "too deep"]))
      #expect(try failureMessage(refused).contains("deeper than 16 levels"))
    }
  }
}

func plainGroup(_ space: Space, _ id: String) async throws -> GroupID {
  try await space.writer.write { db in
    try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00Z')", arguments: [id])
  }
  return GroupID(rawValue: id)
}
