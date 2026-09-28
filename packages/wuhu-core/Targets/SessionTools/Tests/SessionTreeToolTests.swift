import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
@_spi(Testing) import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

private func creating(_ space: Space) -> ToolExecutor {
  ToolExecutor(space: space, resolveModelExecutor: { provider, model, effort in
    .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
  })
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
  for conversation in try await space.sessions.conversations(member: session.rawValue) where conversation.kind == .dmSession {
    found += try await space.sessions.messages(conversation: conversation.id)
  }
  return found
}

struct SessionTreeToolTests {
  @Test func anAgentChildHasABoxAndAnswersItsParentsRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: creating(space), session: parent)

      let child = try created(try await world.run("create_session", .object([
        "title": "researcher", "kind": "agent", "expects_reply": .bool(true), "message": "look into it",
      ])))
      let record = try await space.sessions.record(child.sessionID)
      #expect(record.kind == .agent)
      #expect(record.parent == parent)
      #expect(try await space.sessions.conversation(ConversationID(child.sessionID.rawValue)).kind == .box)
      let request = try #require(child.requestID)
      _ = try await space.sessions.drainQueue(child.sessionID)

      var childWorld = ToolWorld(executor: creating(space), session: child.sessionID)
      let report = try await childWorld.run("report", .object([
        "request_id": .string(request.rawValue), "kind": "final", "content": "found it",
      ]))
      guard case .report = report else { throw Mismatch("expected a report, got \(report)") }
    }
  }

  @Test func anAgentTemplateMakesAnAgentAndAnExplicitKindWins() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/templates/scribe/template.json", Data(#"{"kind":"agent"}"#.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/templates/scribe/AGENTS.md", Data("take notes".utf8), ifMatch: nil)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: creating(space), session: parent)

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
      let researcher = try await makeSession(space, name: "researcher")
      var world = ToolWorld(executor: creating(space), session: researcher)

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
      var workerWorld = ToolWorld(executor: creating(space), session: worker.sessionID)
      let fromTask = try await workerWorld.run("create_session", .object(["title": "x", "top_level": .bool(true)]))
      #expect(try failureMessage(fromTask).contains("only an agent may create a top-level session"))
    }
  }

  @Test func aChildTakesItsCreatorsGroupAndOnlyATopLevelAgentNamesOne() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let alice = try await space.ensurePersonalGroup(account: try await space.addAccount(kind: .human, name: nil).id)
      let bob = try await space.ensurePersonalGroup(account: try await space.addAccount(kind: .human, name: nil).id)
      let agent = try await makeSession(space, name: "agent", group: alice)
      var world = ToolWorld(executor: creating(space), session: agent)

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

  @Test func aMessageWithoutARequestReachesTheChildAsADMAndARetryDoesNotRepeatIt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: creating(space), session: parent)

      let first = try created(try await world.run(
        "create_session", .object(["title": "  primed  ", "message": "context for a human"]), id: "call-1",
      ))
      #expect(first.title == "primed")
      #expect(try await space.sessions.record(first.sessionID).title == "primed")
      let replay = try created(try await world.run(
        "create_session", .object(["title": "primed", "message": "context for a human"]), id: "call-1",
      ))
      #expect(replay.sessionID == first.sessionID)
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
      var level = try await makeSession(space, name: "root")
      for depth in 2 ... SessionStore.depthLimit {
        var world = ToolWorld(executor: creating(space), session: level)
        level = try created(try await world.run("create_session", .object(["title": .string("level \(depth)")]))).sessionID
      }
      var deepest = ToolWorld(executor: creating(space), session: level)
      let refused = try await deepest.run("create_session", .object(["title": "too deep"]))
      #expect(try failureMessage(refused).contains("deeper than 16 levels"))
    }
  }

  @Test func aFailedCloneNamesTheNewSessionAndARetryOfTheCallFinishesIt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/templates/coder/template.json", Data(#"{"kind":"task"}"#.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/templates/coder/AGENTS.md", Data("write code".utf8), ifMatch: nil)
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: creating(space), session: parent)
      let arguments: ToolArguments = .object([
        "title": "coder", "template": "coder", "expects_reply": .bool(true), "message": "go",
      ])

      await space.failTemplateClones("the disk is full")
      let failed = try failureMessage(try await world.run("create_session", arguments, id: "call-1"))
      let half = try created(try #require(try await space.sessions.receipt(parent, toolCallID: ToolCallID("call-1"))))
      #expect(failed == "create_session: session \(half.sessionID.rawValue) was created, but internal: the disk is full")
      #expect(half.cloneOwed == true)
      #expect(try await directMessages(space, to: half.sessionID).isEmpty, "no brief before the home is ready")

      let again = try failureMessage(try await world.retry("create_session", arguments, id: "call-1"))
      #expect(again == failed)

      await space.failTemplateClones(nil)
      let finished = try created(try await world.retry("create_session", arguments, id: "call-1"))
      #expect(finished.sessionID == half.sessionID)
      #expect(finished.requestID != nil)
      let home = SessionHome.path(of: half.sessionID) + "/AGENTS.md"
      #expect(try await space.fs(.shared).read(home).1 == Data("write code".utf8))
      #expect(try created(try #require(try await space.sessions.receipt(parent, toolCallID: ToolCallID("call-1")))).cloneOwed == nil)
      #expect(try await directMessages(space, to: half.sessionID).count == 1)
    }
  }
}
