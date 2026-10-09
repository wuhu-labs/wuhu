import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import Testing

// A task works for its parent. No route lets a person wake one; the parent's
// request and the task's reports still flow.
@Suite struct TaskInputRouteTests {
  struct Tree {
    let harness: SessionHarness
    let parent: SessionID
    let task: SessionID
    let person: String
  }

  func tree() async throws -> Tree {
    let harness = try await SessionHarness()
    let parent = try await harness.createSession(title: "orchestrator")
    let task = try await harness.store.createSession(
      group: .shared,
      title: "coder", kind: .task, parent: parent, createdBy: parent.rawValue,
      executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
    )
    return Tree(harness: harness, parent: parent, task: task, person: try await harness.mintPersona())
  }

  func code(_ response: Response) async throws -> String? {
    guard case let .object(fields)? = JSONValue.parse(try await response.text()),
          case let .string(code)? = fields["code"]
    else { return nil }
    return code
  }

  @Test func aPersonCannotWakeATaskByAnyRoute() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let task = t.task.rawValue

      for (route, value) in [("session", task), ("user", task)] {
        let refused = try await t.harness.post(
          "/v1/conversation/message",
          .object(["message": "hi", route: .string(value), "identity": .string(t.person)]),
        )
        #expect(refused.status == .forbidden, "\(route)")
        #expect(try await code(refused) == (route == "user" ? "humanAgentDM" : "taskInput"), "\(route)")
      }

      let group = try await t.harness.store.createConversation(members: [t.person, task], in: .shared)
      let mentionedAlone = try await t.harness.post(
        "/v1/conversation/message",
        .object([
          "message": .string("@\(task) status?"), "conversation": .string(group.rawValue),
          "identity": .string(t.person),
        ]),
      )
      #expect(mentionedAlone.status == .forbidden)
      #expect(try await t.harness.store.messages(conversation: group).isEmpty)

      // In the parent's box the owner hears it; the task is skipped.
      let taskNote = try await t.harness.store.post(
        .box(t.parent), messageID: MessageID("t1"), sender: Sender(id: task, timeZone: .gmt),
        senderSession: t.task, content: .init(text: "done"),
      )
      let mentioned = try await t.harness.call(
        "/v1/conversation/message",
        .object([
          "message": .string("@\(task) and?"), "session": .string(t.parent.rawValue),
          "identity": .string(t.person),
        ]),
        as: ConversationPostOutput.self,
      )
      #expect(mentioned.delivered == [t.parent.rawValue])
      let replied = try await t.harness.call(
        "/v1/conversation/message",
        .object([
          "message": "about that", "session": .string(t.parent.rawValue),
          "replyTarget": .string(taskNote.message.id.rawValue), "identity": .string(t.person),
        ]),
        as: ConversationPostOutput.self,
      )
      #expect(replied.delivered == [t.parent.rawValue])

      let restartWithMessage = try await t.harness.post(
        "/v1/session/\(task)/restart", .object(["message": "start here", "identity": .string(t.person)]),
      )
      #expect(restartWithMessage.status == .forbidden)
      #expect(try await code(restartWithMessage) == "taskInput")
      let bare = try await t.harness.call("/v1/session/\(task)/restart", .null, as: SessionRestartOutput.self)
      #expect(bare.generation == 1, "the refused restart changed nothing")
      #expect(try await !t.harness.store.transcript(t.task).hasWork)

      let instructed = try await t.harness.post(
        "/v1/session/\(task)/compact", .object(["instructions": "keep the plan"]),
      )
      #expect(instructed.status == .forbidden)
      #expect(try await code(instructed) == "taskInput")
      #expect(try await t.harness.store.pendingCommand(t.task) == nil)
      #expect(try await t.harness.post("/v1/session/\(task)/compact", .null).status == .ok)
      #expect(try await t.harness.store.pendingCommand(t.task) == .compact(instructions: nil))
    }
  }

  @Test func aPersonCreatesAgentsOnlyAndASessionStillCreatesTasks() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let fs = await t.harness.space.fs(.shared)
      _ = try await fs.write(
        "/templates/coder/template.json",
        Data(#"{"kind":"task","provider":"testing","model":"test-model"}"#.utf8),
        ifMatch: nil,
      )

      for body: JSONValue in [
        .object(["kind": "task", "title": "t", "provider": "testing", "model": "test-model"]),
        .object(["title": "t", "template": "coder"]),
      ] {
        let refused = try await t.harness.post("/v1/session", body)
        #expect(refused.status == .forbidden)
        #expect(try await code(refused) == "taskInput")
      }
      let agent = try await t.harness.call(
        "/v1/session", .object(["kind": "agent", "title": "a", "template": "coder"]), as: SessionCreateOutput.self,
      )
      #expect(agent.kind == .agent, "an explicit agent wins over a task template")

      let spawned = try await callResult(
        t.harness, t.parent.rawValue, tool: "create_session",
        .object(["title": "helper", "template": "coder", "expects_reply": true, "message": "go"]),
      )
      #expect(!isToolError(spawned))
      let dm = try #require(try await t.harness.store.conversations(member: t.parent.rawValue).first {
        $0.kind == .dmSession && !$0.members.contains { $0.member == t.task.rawValue }
      })
      let child = try #require(dm.members.first { $0.member != t.parent.rawValue })
      let record = try await t.harness.store.record(SessionID(child.member))
      #expect(record.kind == .task)
      #expect(record.parent == t.parent)
    }
  }

  @Test func aParentsRequestAndTheTasksReportsStillFlow() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let parent = t.parent.rawValue
      let task = t.task.rawValue

      let requested = try await callResult(
        t.harness, parent, tool: "request", .object(["task": .string(task), "message": "do it"]),
      )
      #expect(!isToolError(requested))
      let followed = try await callResult(
        t.harness, parent, tool: "send_message", .object(["session": .string(task), "message": "also this"]),
      )
      #expect(!isToolError(followed))

      let dm = try #require(try await t.harness.store.conversations(member: task).first { $0.kind == .dmSession })
      let request = try #require(try await t.harness.store.messages(conversation: dm.id).first?.requestID)
      // The task has seen its request once its queue drains; only then may it report.
      _ = try await t.harness.store.drainQueue(t.task)
      for kind in ["progress", "final"] {
        let reported = try await callResult(
          t.harness, task, tool: "report",
          .object(["request_id": .string(request.rawValue), "kind": .string(kind), "content": "news"]),
        )
        #expect(!isToolError(reported), "\(kind)")
      }

      let messages = try await t.harness.store.messages(conversation: dm.id)
      #expect(messages.map(\.kind) == [.request, .message, .progress, .final])
      #expect(messages.map(\.senderSession) == [t.parent, t.parent, t.task, t.task])
    }
  }
}
