import struct Credentials.CredentialResolver
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import MachineContract
import ServeTesting
import SessionDomain
import SpaceContract
@_spi(Testing) import SpaceCore
@testable import SpaceServer
import Testing

// A session's exec token through the real handler: what it may do, as whom,
// and when it stops working.
@Suite(.deterministicDependencies) struct SessionGateTests {
  struct Tree {
    let harness: SessionHarness
    let tokens: ExecTokens
    let parent: SessionID
    let child: SessionID
    let stranger: SessionID
    let exec: ExecID
    let token: String
  }

  func tree(dev: Bool = true, timeout: Double? = nil, credentials: CredentialResolver = .unavailable) async throws -> Tree {
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let harness = try await SessionHarness(dev: dev, credentials: credentials, execTokens: tokens)
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let parent = try await harness.store.createSession(group: .shared, title: "orchestrator", kind: .agent, createdBy: "owner", executor: model)
    let child = try await harness.store.createSession(
      group: .shared,
      title: "coder", kind: .task, parent: parent, createdBy: parent.rawValue, executor: model,
    )
    let stranger = try await harness.store.createSession(group: .shared, title: "stranger", kind: .agent, createdBy: "owner", executor: model)
    let machine = try await harness.space.addMachine(name: "box")
    let exec = try await harness.space.mintExec(machine: machine.id, caller: parent.rawValue)
    let token = tokens.credential(session: parent, exec: exec.id, timeout: timeout, now: Date()).token
    return Tree(harness: harness, tokens: tokens, parent: parent, child: child, stranger: stranger, exec: exec.id, token: token)
  }

  // A task archives only itself and what it created; a top-level
  // agent is an admin of its group and archives any session in it.
  @Test func archivingNeedsTheSessionItsCreatorOrAnAdminOfItsGroup() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: .shared))
      let childExec = try await t.harness.space.mintExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
      let refused = try await t.harness.post("/v1/session/\(t.stranger.rawValue)/archive", .null, bearer: childToken)
      #expect(refused.status == .forbidden)
      #expect(try await refused.text().contains(
        "\(t.child.rawValue) may not archive or unarchive session \(t.stranger.rawValue): only the session itself, its creator and admins of its group may",
      ))
      #expect(try await t.harness.store.record(t.stranger).lifecycle == .live)

      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let others = try await t.harness.store.createSession(
        group: .shared, title: "other task", kind: .task, parent: t.stranger, createdBy: t.stranger.rawValue, executor: model,
      )
      #expect(try await t.harness.post("/v1/session/\(others.rawValue)/archive", .null, bearer: t.token).status == .ok)
      #expect(try await t.harness.store.record(others).lifecycle != .live)
    }
  }

  @Test func tagsOnItsOwnChildWork() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let tagged = try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", .object(["tags": ["wuhu:37"]]), bearer: t.token)
      #expect(tagged.status == .ok)
      #expect(try await t.harness.store.record(t.child).tags == ["wuhu:37"])
    }
  }

  @Test func verbsOnlyTheWalletHasAreRefusedWithTheExactMessage() async throws {
    try await withSessionDeps {
      let t = try await tree()
      for (method, path) in [
        (Fetch.Method.get, "/v1/users"), (.get, "/v1/accounts"), (.get, "/v1/secret"),
        (.post, "/v1/machine"), (.get, "/v1/providers"), (.get, "/v1/session/\(t.child.rawValue)/transcript"),
      ] {
        var request = Request(url: URL(string: "http://space\(path)")!, method: method)
        request.headers[.authorization] = "Bearer " + t.token
        let response = try await t.harness.api(request)
        #expect(response.status == .forbidden, "\(path)")
        #expect(try await response.text().contains(sessionRefusalMessage), "\(path)")
      }
      let sync = try await t.harness.post("/v1/tools/sync", .object(["path": "/x.md"]), bearer: t.token)
      #expect(sync.status == .forbidden)
    }
  }

  @Test func tableHTTPChecksReadableSharedLayerWrites() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let account = try await t.harness.space.addAccount(kind: .human, name: "reader")
      let group = try await t.harness.space.ensurePersonalGroup(account: account.id)
      let reader = try await t.harness.store.createSession(group: group, title: "reader", kind: .agent, createdBy: "reader", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: group))
      let exec = try await t.harness.space.mintExec(machine: machine.id, caller: reader.rawValue)
      let token = t.tokens.credential(session: reader, exec: exec.id, timeout: nil, now: Date()).token
      let path = "wuhu://shared.localspace/.agents/skills/test/data.table"
      let header: JSONValue = ["columns": [["name": "s", "type": "string"]]]
      let refused = try await t.harness.post("/v1/tools/table.create", ["path": .string(path), "header": header], bearer: token)
      #expect(refused.status == .unprocessableContent)
      #expect(try await refused.json(ToolError.self).code == .unauthorized)
      let created = try await t.harness.call("/v1/tools/table.create", ["path": .string(path), "header": header], as: TableWriteOutput.self, bearer: t.token)
      #expect(try await t.harness.post("/v1/tools/table.schema", ["path": .string(path)], bearer: token).status == .ok)
      for (verb, input) in [
        ("table.alter", JSONValue.object(["path": .string(path), "header": header, "ifMatch": .string(created.token)])),
        ("table.mutate", JSONValue.object(["path": .string(path), "ops": [["kind": "insert", "values": ["injected"]]]])),
      ] {
        let response = try await t.harness.post("/v1/tools/\(verb)", input, bearer: token)
        #expect(response.status == .unprocessableContent)
        #expect(try await response.json(ToolError.self).code == .unauthorized)
      }
    }
  }

  @Test func newTablesAndCheckoutActUnderTheSessionHomeRule() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let own = "/_/sessions/\(t.parent.rawValue)"
      let foreign = "/_/sessions/\(t.stranger.rawValue)"
      func tool(_ name: String, _ body: JSONValue) async throws -> Response {
        try await t.harness.post("/v1/tools/\(name)", body, bearer: t.token)
      }

      // new: next to its template, into an own folder, never into another home
      let template = "---\ntemplate:\n  strategy: incr\n  prefix: J\n---\nhi"
      _ = try await t.harness.call(
        "/v1/tools/write", .object(["path": .string("\(own)/tpl/j.md"), "content": .string(template)]),
        as: WriteOutput.self, bearer: t.token,
      )
      let made = try await t.harness.call(
        "/v1/tools/new", .object(["template": .string("\(own)/tpl/j.md")]), as: NewOutput.self, bearer: t.token,
      )
      #expect(made.path == "\(own)/tpl/J-1.md")
      let into = try await t.harness.call(
        "/v1/tools/new", .object(["template": .string("\(own)/tpl/j.md"), "in": .string("\(own)/log")]),
        as: NewOutput.self, bearer: t.token,
      )
      #expect(into.path.hasPrefix("\(own)/log/"))
      let intoForeign = try await tool("new", .object(["template": .string("\(own)/tpl/j.md"), "in": .string(foreign)]))
      #expect(intoForeign.status == .unprocessableContent)
      let besideForeign = try await tool("new", .object(["template": .string("\(foreign)/j.md")]))
      #expect(besideForeign.status == .unprocessableContent)

      // table.*: own home works, another's is refused
      let header: JSONValue = .object(["columns": .array([.object(["name": "s", "type": "string"])])])
      #expect(try await tool("table.create", .object(["path": .string("\(own)/t.table"), "header": header])).status == .ok)
      let insert: JSONValue = .array([.object(["kind": "insert", "values": .array(["x"])])])
      #expect(try await tool("table.mutate", .object(["path": .string("\(own)/t.table"), "ops": insert])).status == .ok)
      let schema = try await t.harness.call("/v1/tools/table.schema", ["path": .string("\(own)/t.table")], as: TableSchemaOutput.self, bearer: t.token)
      #expect(schema.header.columns.map(\.name) == ["s"])
      #expect(try await tool("table.alter", .object(["path": .string("\(own)/t.table"), "header": header, "ifMatch": .string(schema.token)])).status == .ok)
      for name in ["table.create", "table.alter"] {
        let refused = try await tool(name, .object(["path": .string("\(foreign)/t.table"), "header": header]))
        #expect(refused.status == .unprocessableContent, "\(name)")
      }
      let mutateForeign = try await tool("table.mutate", .object(["path": .string("\(foreign)/t.table"), "ops": insert]))
      #expect(mutateForeign.status == .unprocessableContent)

      // checkout: restores an own file, never one in another home
      let first = try await t.harness.call(
        "/v1/tools/write", .object(["path": .string("\(own)/c.md"), "content": "one"]), as: WriteOutput.self, bearer: t.token,
      )
      _ = try await t.harness.call(
        "/v1/tools/write", .object(["path": .string("\(own)/c.md"), "content": "two", "ifMatch": .string(first.token)]),
        as: WriteOutput.self, bearer: t.token,
      )
      let rev = try #require(first.rev)
      #expect(try await tool("checkout", .object(["path": .string("\(own)/c.md"), "rev": .integer(rev)])).status == .ok)
      let checkoutForeign = try await tool("checkout", .object(["path": .string("\(foreign)/c.md"), "rev": .integer(rev)]))
      #expect(checkoutForeign.status == .unprocessableContent)
    }
  }

  @Test func fileToolsActUnderTheSessionHomeRule() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let own = try await t.harness.post(
        "/v1/tools/write", .object(["path": .string("/_/sessions/\(t.parent.rawValue)/notes.md"), "content": "mine"]), bearer: t.token,
      )
      #expect(own.status == .ok)
      let foreign = try await t.harness.post(
        "/v1/tools/write", .object(["path": .string("/_/sessions/\(t.stranger.rawValue)/notes.md"), "content": "theirs"]), bearer: t.token,
      )
      #expect(foreign.status == .unprocessableContent)
      let moved = try await t.harness.post(
        "/v1/tools/mv",
        .object(["from": .string("/_/sessions/\(t.parent.rawValue)/notes.md"), "to": .string("/_/sessions/\(t.stranger.rawValue)/x.md")]),
        bearer: t.token,
      )
      #expect(moved.status == .unprocessableContent)
      let put = try await t.harness.put("/v1/f/_/sessions/\(t.stranger.rawValue)/y.md", .string("x"), bearer: t.token)
      #expect(put.status == .unprocessableContent)
      let read = try await t.harness.post("/v1/tools/read", .object(["path": .string("/_/sessions/\(t.parent.rawValue)/notes.md")]), bearer: t.token)
      #expect(read.status == .ok)
    }
  }

  @Test func createMakesAChildTaskByDefaultAndTopLevelIsForAgents() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let created = try await t.harness.call(
        "/v1/session", .object(["title": "helper"]), as: SessionCreateOutput.self, bearer: t.token,
      )
      #expect(created.kind == .task)
      #expect(created.parent == t.parent.rawValue)
      #expect(created.model == "test-model")

      let topLevel = try await t.harness.call(
        "/v1/session", .object(["title": "peer", "kind": "agent", "topLevel": true]), as: SessionCreateOutput.self, bearer: t.token,
      )
      #expect(topLevel.parent == nil)
      #expect(topLevel.kind == .agent)

      let machine = try await t.harness.space.addMachine(name: "box2")
      let childExec = try await t.harness.space.mintExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
      let refused = try await t.harness.post("/v1/session", .object(["title": "x", "kind": "agent", "topLevel": true]), bearer: childToken)
      #expect(refused.status == .unprocessableContent)
    }
  }

  @Test func requestOpensOnItsOwnTask() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let opened = try await t.harness.call(
        "/v1/session/\(t.child.rawValue)/request", .object(["message": "do it"]), as: SessionRequestOutput.self, bearer: t.token,
      )
      #expect(!opened.requestId.isEmpty)
      let foreign = try await t.harness.post("/v1/session/\(t.stranger.rawValue)/request", .object(["message": "do it"]), bearer: t.token)
      #expect(foreign.status == .unprocessableContent)
    }
  }

  @Test func sendToASessionIsADirectMessageFromThisSession() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let sent = try await t.harness.call(
        "/v1/conversation/message", .object(["session": .string(t.stranger.rawValue), "message": "hi"]),
        as: ConversationPostOutput.self, bearer: t.token,
      )
      #expect(sent.conversationId != t.stranger.rawValue)
      let messages = try await t.harness.store.messages(conversation: ConversationID(sent.conversationId))
      #expect(messages.last?.senderSession == t.parent)
    }
  }

  // The hub's verbs through the gate: a report closes the request it names,
  // a subscription is the session's own slot, a title is only its own, and
  // a device is a top-level agent's to drive.
  @Test func reportSubscriptionTitleAndDeviceCommandRunOnTheHub() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: .shared))
      let childExec = try await t.harness.space.mintExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
      _ = try await t.harness.store.openRequest(on: t.child, from: t.parent, messageID: .init("ask-1"), text: "work", deadline: nil)
      // The request is open on the child once it has taken the message.
      _ = try await t.harness.store.drainQueue(t.child)
      let reported = try await t.harness.call(
        "/v1/request/ask-1/report", .object(["kind": "final", "content": "done"]), as: RequestReportOutput.self, bearer: childToken,
      )
      let messages = try await t.harness.store.messages(conversation: ConversationID(reported.conversationId))
      let final = messages.first { $0.id.rawValue == reported.messageId }
      #expect(final?.kind == .final)
      #expect(final?.senderSession == t.child)
      let closed = try await t.harness.post("/v1/request/ask-1/report", .object(["kind": "final", "content": "again"]), bearer: childToken)
      #expect(closed.status == .unprocessableContent)

      let timer = try await t.harness.call(
        "/v1/subscription", .object(["timer": ["message": "ping", "inSeconds": 60]]), as: SubscriptionOutput.self, bearer: t.token,
      )
      #expect(timer.kind == .timer)
      #expect(timer.fireAt != nil)
      #expect(try await t.harness.store.armedSubscriptions(t.parent).map(\.slot.id.rawValue) == [timer.id])
      let both = try await t.harness.post(
        "/v1/subscription", .object(["timer": ["message": "x", "inSeconds": 1], "observe": ["sql": "SELECT 1"]]), bearer: t.token,
      )
      #expect(both.status == .badRequest)
      var cancel = Request(url: URL(string: "http://space/v1/subscription/\(timer.id)")!, method: .delete)
      cancel.headers[.authorization] = "Bearer " + t.token
      let ended = try await t.harness.api(cancel)
      #expect(ended.status == .ok)
      #expect(try await ended.text().contains(timer.id))
      #expect(try await t.harness.store.armedSubscriptions(t.parent).isEmpty)
      #expect(try await t.harness.api(cancel).status == .unprocessableContent)

      let titled = try await t.harness.call(
        "/v1/session/\(t.parent.rawValue)/title", .object(["title": "lead"]), as: SessionTitleOutput.self, bearer: t.token,
      )
      #expect(titled.title == "lead")
      #expect(try await t.harness.store.record(t.parent).title == "lead")
      #expect(try await t.harness.post("/v1/session/\(t.child.rawValue)/title", .object(["title": "x"]), bearer: t.token).status == .notFound)

      let account = try await t.harness.space.addAccount(kind: .human, name: "reader")
      _ = try await t.harness.space.addKey(testPubkey("phone"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let device = try await t.harness.space.upsertDevice(pubkey: testPubkey("phone"), installation: "inst-1", kind: "phone", name: "Phone")
      let issued = try await t.harness.call(
        "/v1/device/\(device.id)/command", .object(["payload": ["sidebar": "everything"]]), as: DeviceCommandOutput.self, bearer: t.token,
      )
      #expect(issued.n == 1)
      let refused = try await t.harness.post("/v1/device/\(device.id)/command", .object(["payload": ["sidebar": "everything"]]), bearer: childToken)
      #expect(refused.status == .unprocessableContent)
      #expect(try await refused.text().contains("top-level agents"))
    }
  }

  // The tool call a request runs for is its idempotency key: the same call
  // again gets the first answer back, not a second slot, child or cancel.
  @Test func aRepeatedToolCallReplaysItsFirstAnswer() async throws {
    try await withSessionDeps {
      let t = try await tree()
      func call(_ method: Fetch.Method, _ path: String, _ body: JSONValue, toolCall: String) async throws -> (Status, String) {
        try await toolCalled(t.harness, bearer: t.token, method, path, body, toolCall: toolCall)
      }
      let armed = try await call(.post, "/v1/subscription", .object(["timer": ["message": "ping", "inSeconds": 60]]), toolCall: "tc-timer")
      #expect(armed.0 == .ok)
      #expect(try await call(.post, "/v1/subscription", .object(["timer": ["message": "ping", "inSeconds": 60]]), toolCall: "tc-timer") == armed)
      let slots = try await t.harness.store.armedSubscriptions(t.parent)
      #expect(slots.count == 1)
      let id = try #require(slots.first?.slot.id.rawValue)

      let cancelled = try await call(.delete, "/v1/subscription/\(id)", .null, toolCall: "tc-cancel")
      #expect(cancelled.0 == .ok)
      // The slot is gone, yet the retried cancel is answered as the first was.
      #expect(try await call(.delete, "/v1/subscription/\(id)", .null, toolCall: "tc-cancel") == cancelled)
      #expect(try await call(.delete, "/v1/subscription/\(id)", .null, toolCall: "tc-cancel-2").0 == .unprocessableContent)

      let created = try await call(.post, "/v1/session", .object(["title": "helper"]), toolCall: "tc-create")
      #expect(created.0 == .ok)
      #expect(try await call(.post, "/v1/session", .object(["title": "helper"]), toolCall: "tc-create") == created)
      let helpers = try await t.harness.space.query("SELECT id FROM sessions WHERE title = 'helper'", as: .shared(.anonymous)).rows
      #expect(helpers.count == 1)

      // A failure is not a receipt: the same call runs again.
      let refused = try await call(.post, "/v1/session/\(t.stranger.rawValue)/request", .object(["message": "do it"]), toolCall: "tc-request")
      #expect(refused.0 == .unprocessableContent)
      #expect(try await call(.post, "/v1/session/\(t.stranger.rawValue)/request", .object(["message": "do it"]), toolCall: "tc-request").0 == .unprocessableContent)

      // An arm retried after its slot is gone is answered as the first was
      // and arms nothing.
      let gone = try await call(.post, "/v1/subscription", .object(["timer": ["message": "once", "inSeconds": 60]]), toolCall: "tc-timer-gone")
      #expect(gone.0 == .ok)
      let goneID = try #require(JSONValue.parse(gone.1)?.object?["id"]?.stringValue)
      try await t.harness.store.cancelSubscription(t.parent, subscriptionID: SubscriptionID(goneID))
      #expect(try await call(.post, "/v1/subscription", .object(["timer": ["message": "once", "inSeconds": 60]]), toolCall: "tc-timer-gone") == gone)
      #expect(try await t.harness.store.armedSubscriptions(t.parent).allSatisfy { $0.slot.id.rawValue != goneID })

      // A device is driven once: the retry answers with the first command's n.
      let account = try await t.harness.space.addAccount(kind: .human, name: "reader")
      _ = try await t.harness.space.addKey(testPubkey("phone"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let device = try await t.harness.space.upsertDevice(pubkey: testPubkey("phone"), installation: "inst-1", kind: "phone", name: "Phone")
      let driven = try await call(.post, "/v1/device/\(device.id)/command", .object(["payload": ["sidebar": "everything"]]), toolCall: "tc-device")
      #expect(driven.0 == .ok)
      #expect(try await call(.post, "/v1/device/\(device.id)/command", .object(["payload": ["sidebar": "everything"]]), toolCall: "tc-device") == driven)
      let again = try await call(.post, "/v1/device/\(device.id)/command", .object(["payload": ["sidebar": "everything"]]), toolCall: "tc-device-2")
      #expect(JSONValue.parse(again.1)?.object?["n"] == .integer(2))

      // A title call retried after a later one answers as it first did and
      // leaves the later title standing.
      let named = try await call(.post, "/v1/session/\(t.parent.rawValue)/title", .object(["title": "lead"]), toolCall: "tc-title")
      #expect(named.0 == .ok)
      #expect(try await call(.post, "/v1/session/\(t.parent.rawValue)/title", .object(["title": "lead, renamed"]), toolCall: "tc-title-2").0 == .ok)
      #expect(try await call(.post, "/v1/session/\(t.parent.rawValue)/title", .object(["title": "lead"]), toolCall: "tc-title") == named)
      #expect(try await t.harness.store.record(t.parent).title == "lead, renamed")
    }
  }

  // Two runs of one tool call at once (a worker retrying while its first
  // run still runs) act once: the answer is looked up in the write that
  // makes the effect, not before it.
  @Test func overlappingRunsOfOneToolCallActOnce() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let call: @Sendable (Fetch.Method, String, JSONValue, String) async throws -> (Status, String) = { method, path, body, toolCall in
        try await toolCalled(t.harness, bearer: t.token, method, path, body, toolCall: toolCall)
      }

      let timer: JSONValue = .object(["timer": ["message": "ping", "inSeconds": 60]])
      async let firstArm = call(.post, "/v1/subscription", timer, "tc-timer")
      async let secondArm = call(.post, "/v1/subscription", timer, "tc-timer")
      let armed = try await (firstArm, secondArm)
      #expect(armed.0.0 == .ok)
      #expect(armed.0 == armed.1)
      let slots = try await t.harness.store.armedSubscriptions(t.parent)
      #expect(slots.count == 1)
      let id = try #require(slots.first?.slot.id.rawValue)

      async let firstCancel = call(.delete, "/v1/subscription/\(id)", .null, "tc-cancel")
      async let secondCancel = call(.delete, "/v1/subscription/\(id)", .null, "tc-cancel")
      let cancelled = try await (firstCancel, secondCancel)
      #expect(cancelled.0.0 == .ok)
      #expect(cancelled.0 == cancelled.1)
      #expect(try await t.harness.store.armedSubscriptions(t.parent).isEmpty)

      let account = try await t.harness.space.addAccount(kind: .human, name: "reader")
      _ = try await t.harness.space.addKey(testPubkey("phone"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let device = try await t.harness.space.upsertDevice(pubkey: testPubkey("phone"), installation: "inst-1", kind: "phone", name: "Phone")
      let command: JSONValue = .object(["payload": ["sidebar": "everything"]])
      async let firstDrive = call(.post, "/v1/device/\(device.id)/command", command, "tc-device")
      async let secondDrive = call(.post, "/v1/device/\(device.id)/command", command, "tc-device")
      let driven = try await (firstDrive, secondDrive)
      #expect(driven.0.0 == .ok)
      #expect(driven.0 == driven.1)
      // One command was issued: the next is the second.
      let next = try await call(.post, "/v1/device/\(device.id)/command", command, "tc-device-2")
      #expect(JSONValue.parse(next.1)?.object?["n"] == .integer(2))
    }
  }

  // A request's clocks commit with its message and end with the final that
  // closes it; a retry of either call is the first one again.
  @Test func aRetriedRequestOrReportIsTheFirstOne() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: .shared))
      let childExec = try await t.harness.space.mintExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token

      let ask: JSONValue = .object(["message": "do it", "deadlineSeconds": 60, "stallSeconds": 30])
      let opened = try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session/\(t.child.rawValue)/request", ask, toolCall: "tc-ask")
      #expect(opened.0 == .ok)
      #expect(try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session/\(t.child.rawValue)/request", ask, toolCall: "tc-ask") == opened)
      let requestID = try #require(JSONValue.parse(opened.1)?.object?["requestId"]?.stringValue)
      let clocks = try await t.harness.store.armedSubscriptions(t.parent).map(\.slot.id.rawValue).sorted()
      #expect(clocks == ["deadline.\(requestID)", "stall.\(requestID)"])

      _ = try await t.harness.store.drainQueue(t.child)
      let done: JSONValue = .object(["kind": "final", "content": "done"])
      let reported = try await toolCalled(t.harness, bearer: childToken, .post, "/v1/request/\(requestID)/report", done, toolCall: "tc-done")
      #expect(reported.0 == .ok)
      #expect(try await toolCalled(t.harness, bearer: childToken, .post, "/v1/request/\(requestID)/report", done, toolCall: "tc-done") == reported)
      let conversation = try #require(JSONValue.parse(reported.1)?.object?["conversationId"]?.stringValue)
      let finals = try await t.harness.store.messages(conversation: ConversationID(conversation)).filter { $0.kind == .final }
      #expect(finals.count == 1)
      #expect(try await t.harness.store.armedSubscriptions(t.parent).isEmpty)
      #expect(try await toolCalled(t.harness, bearer: childToken, .post, "/v1/request/\(requestID)/report", done, toolCall: "tc-done-2").0 == .unprocessableContent)
    }
  }

  // A create that left its session unfinished names it, and the same call
  // again finishes that session rather than making another.
  @Test func anIncompleteCreateNamesTheSessionAndItsRetryFinishesIt() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let fs = await t.harness.space.fs(.shared)
      _ = try await fs.write("/templates/night/template.json", Data(#"{"kind":"task"}"#.utf8), ifMatch: nil)
      _ = try await fs.write("/templates/night/AGENTS.md", Data("night rules".utf8), ifMatch: nil)
      await t.harness.space.failTemplateClones("the disk is full")
      let body: JSONValue = .object(["title": "shift", "template": "night"])
      let half = try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session", body, toolCall: "tc-half")
      #expect(half.0 == .unprocessableContent)
      let fields = try #require(JSONValue.parse(half.1)?.object)
      #expect(fields["code"] == .string("incompleteSession"))
      let id = try #require(fields["id"]?.stringValue)
      #expect(fields["message"] == .string("create_session: session \(id) was created, but internal: the disk is full"))
      #expect(try await t.harness.store.record(SessionID(id)).title == "shift")

      await t.harness.space.failTemplateClones(nil)
      let finished = try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session", body, toolCall: "tc-half")
      #expect(finished.0 == .ok)
      #expect(JSONValue.parse(finished.1)?.object?["id"] == .string(id))
      #expect(try await fs.read("/_/sessions/\(id)/AGENTS.md").1 == Data("night rules".utf8))
    }
  }

  @Test func execsAreItsOwnOnly() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.machine(named: "box"))
      let others = try await t.harness.space.mintExec(machine: machine.id)
      let minted = try await t.harness.call(
        "/v1/exec", .object(["machine": .string(machine.id.rawValue)]), as: ExecMintOutput.self, bearer: t.token,
      )
      #expect(try await t.harness.space.execRecord(minted.id)?.caller == t.parent.rawValue)

      let listed = try await t.harness.get("/v1/exec", bearer: t.token)
      let ids = try JSONValueDecoder().decode([ExecStatus].self, from: try #require(JSONValue.parse(try await listed.text()))).map(\.id)
      #expect(Set(ids) == [t.exec, minted.id])

      #expect(try await t.harness.get("/v1/exec/\(others.id.rawValue)", bearer: t.token).status == .notFound)
      #expect(try await t.harness.post("/v1/exec/\(others.id.rawValue)/kill", .null, bearer: t.token).status == .notFound)
      #expect(try await t.harness.get("/v1/exec/\(minted.id.rawValue)", bearer: t.token).status == .ok)
    }
  }

  // The gate's webSocket catch-all is registered before the exec route; the
  // exec route must still win for the session's own exec.
  @Test func itsOwnExecDialsOverWebSocketAndNothingElseDoes() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.machine(named: "box"))
      let others = try await t.harness.space.mintExec(machine: machine.id)

      func dial(_ path: String) async throws -> Status? {
        var headers = RequestHeaders()
        headers.set("connection", "Upgrade")
        headers.set("upgrade", "websocket")
        headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        headers.set("sec-websocket-version", "13")
        headers.set("authorization", "Bearer " + t.token)
        let request = Request(url: URL(string: "http://space\(path)")!, headers: headers)
        switch try await ServeTesting.upgrade(t.harness.handler, request) {
        case let .response(response): return response.status
        case .webSocket: return nil
        }
      }

      #expect(try await dial("/v1/exec/\(t.exec.rawValue)") == nil)
      #expect(try await dial("/v1/exec/\(others.id.rawValue)") == .notFound)
      #expect(try await dial("/v1/sessions/\(t.parent.rawValue)/stream") == .forbidden)
      #expect(try await dial("/v1/anything") == .forbidden)
    }
  }

  @Test func aTokenStopsWorkingWhenItsExecEndsOrItExpires() async throws {
    try await withSessionDeps {
      let t = try await tree(timeout: 60)
      #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .ok)

      let unknown = try await t.harness.get("/v1/server", bearer: ExecTokens.prefix + String(repeating: "0", count: 64))
      #expect(unknown.status == .unauthorized)
      #expect(try await unknown.text().contains("server restarted"))

      #expect(t.tokens.holder(ofBearer: t.token, now: Date().addingTimeInterval(61)) == nil)
      #expect(t.tokens.holder(ofBearer: t.token, now: Date()) != nil)

      try await t.harness.space.finishExec(t.exec, .exited(code: 0))
      let ended = try await t.harness.get("/v1/server", bearer: t.token)
      #expect(ended.status == .unauthorized)
      #expect(try await ended.text().contains("has ended"))
      #expect(t.tokens.holder(ofBearer: t.token, now: Date()) == nil)
    }
  }

  @Test func aMachineDropDoesNotEndTheToken() async throws {
    try await withSessionDeps {
      let t = try await tree(timeout: 60)
      try await t.harness.space.finishExec(t.exec, .machineLost)
      #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .ok)
      #expect(t.tokens.holder(ofBearer: t.token, now: Date()) != nil)

      // The machine came back and the exec ran on; its real exit settles the
      // row, and only that ends the token.
      #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .ok)
      try await t.harness.space.finishExec(t.exec, .exited(code: 0))
      let ended = try await t.harness.get("/v1/server", bearer: t.token)
      #expect(ended.status == .unauthorized)
      #expect(t.tokens.holder(ofBearer: t.token, now: Date()) == nil)
    }
  }

  @Test func cancelledAndReapedExecsEndTheToken() async throws {
    try await withSessionDeps {
      for state in [ExecTerminalState.cancelled, .reaped] {
        let t = try await tree(timeout: 60)
        try await t.harness.space.finishExec(t.exec, state)
        #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .unauthorized)
        #expect(t.tokens.holder(ofBearer: t.token, now: Date()) == nil)
      }
    }
  }

  @Test func theLifeIsTheTimeoutCappedAtADay() {
    let tokens = ExecTokens(spaceURL: "https://space.test")
    let session = SessionID("s")
    let now = Date()
    let long = tokens.credential(session: session, exec: ExecID(rawValue: "ex_aaaaaaaa"), timeout: 7 * 86400, now: now)
    #expect(tokens.holder(ofBearer: long.token, now: now.addingTimeInterval(86399)) != nil)
    #expect(tokens.holder(ofBearer: long.token, now: now.addingTimeInterval(86401)) == nil)
    let again = tokens.credential(session: session, exec: ExecID(rawValue: "ex_bbbbbbbb"), timeout: nil, now: now)
    #expect(tokens.credential(session: session, exec: ExecID(rawValue: "ex_bbbbbbbb"), timeout: nil, now: now) == again)
    #expect(again.token.hasPrefix(ExecTokens.prefix) && again.token.count == 68)
  }

  @Test func anArchivedSessionsTokenIsRefused() async throws {
    try await withSessionDeps {
      let t = try await tree()
      _ = try await t.harness.store.archive(t.parent, grace: .seconds(3600))
      let refused = try await t.harness.get("/v1/server", bearer: t.token)
      #expect(refused.status == .forbidden)
      #expect(try await refused.text().contains("is archived"))
    }
  }

  @Test func theTokenPassesTheWallOfANonDevServer() async throws {
    try await withSessionDeps {
      let t = try await tree(dev: false)
      let tagged = try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", .object(["tags": ["x"]]), bearer: t.token)
      #expect(tagged.status == .ok)
      let anonymous = try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", .object(["tags": ["y"]]))
      #expect(anonymous.status == .unauthorized)
    }
  }
}

extension SessionGateTests {
  @Test func aSessionExecCreatesAndManagesAHumanOnlyChannel() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let alice = try await t.harness.mintPersona()
      let bob = try await t.harness.mintPersona()
      let carol = try await t.harness.mintPersona()
      let output = try await t.harness.call("/v1/conversation", ["members": .array([.string(alice), .string(bob)]), "title": "People"], as: ConversationPostOutput.self, bearer: t.token)
      let id = output.conversationId
      let channel = try await t.harness.store.conversation(ConversationID(id))
      #expect(channel.kind == .users)
      #expect(channel.title == "People")
      #expect(Set(channel.members.map(\.member)) == [alice, bob])
      let add = try await t.harness.post("/v1/channel/\(id)/add", ["people": .array([.string(carol)])], bearer: t.token)
      #expect(add.status == .ok)
      let remove = try await t.harness.post("/v1/channel/\(id)/remove", ["people": .array([.string(carol)])], bearer: t.token)
      #expect(remove.status == .ok)
      let rename = try await t.harness.post("/v1/channel/\(id)/rename", ["title": "Team"], bearer: t.token)
      #expect(rename.status == .ok)
      let refused = try await t.harness.post("/v1/channel/\(id)/add", ["people": .array([.string(t.parent.rawValue)])], bearer: t.token)
      #expect(refused.status == .unprocessableContent)
      #expect(try await refused.text().contains("invalidArgument"))
      let plain = try await t.harness.call("/v1/conversation/message", ["conversation": .string(id), "identity": .string(alice), "message": "hello people"], as: ConversationPostOutput.self)
      #expect(plain.delivered.isEmpty)
      let mention = try await t.harness.call("/v1/conversation/message", ["conversation": .string(id), "identity": .string(alice), "message": .string("@\(t.parent.rawValue) help")], as: ConversationPostOutput.self)
      #expect(mention.delivered == [t.parent.rawValue])
      _ = try await t.harness.call("/v1/conversation/message", ["conversation": .string(id), "replyTarget": .string(mention.messageId), "message": "answer"], as: ConversationPostOutput.self, bearer: t.token)
      let next = try await t.harness.call("/v1/conversation/message", ["conversation": .string(id), "identity": .string(bob), "message": "next without mention"], as: ConversationPostOutput.self)
      #expect(next.delivered == [t.parent.rawValue])
      #expect(try await t.harness.store.conversation(ConversationID(id)).members.allSatisfy { $0.kind == .user })
      let strangerPost = try await t.harness.post("/v1/conversation/message", ["conversation": .string(id), "identity": .string(carol), "message": "refused"])
      #expect(strangerPost.status == .notFound)
      #expect(try await t.harness.get("/v1/conversation/\(id)/messages", query: ["identity": carol]).status == .notFound)
      let aliceAccount = try #require(try await t.harness.space.persona(named: alice)?.account)
      let (aliceBearer, _) = try await t.harness.enrolledBearer(account: aliceAccount)
      #expect(try await t.harness.get("/v1/conversation/\(id)/messages", bearer: aliceBearer).status == .ok)
      let read = try await t.harness.get("/v1/conversation/\(id)/messages", bearer: t.token)
      #expect(read.status == .ok)
      let list = try await t.harness.get("/v1/conversations", bearer: t.token)
      #expect(list.status == .ok)
      #expect(try await list.text().contains("Team"))
    }
  }
}

import Crypto
import OperationClient
import OperationProtocol
import Synchronization

extension SessionGateTests {
  @Test func v2CredentialsKeepSessionAuthorityAndExpireWithoutRenewal() async throws {
    try await withSessionDeps {
      let t = try await tree(dev: false)
      let now = Date()
      let active = Mutex(true)
      let credential = try t.tokens.credential(session: t.parent, group: .shared, scope: "script", key: "exec", timeout: .seconds(60), now: now, active: { active.withLock { $0 } })
      let token = try #require(credential.object?["token"]?.stringValue)
      #expect(token.hasPrefix(ExecTokens.prefix) && token.count == 68)
      #expect(try t.tokens.credential(session: t.parent, group: .shared, scope: "script", key: "exec", timeout: .seconds(300), now: now.addingTimeInterval(1), active: { false }) == credential)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .ok)
      #expect(try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", ["tags": ["v2"]], bearer: token).status == .ok)
      #expect(try await t.harness.get("/v1/users", bearer: token).status == .forbidden)
      #expect(try await t.harness.get("/v1/server?group=another", bearer: token).status == .forbidden)
      let expired = await sessionVerdict(token, tokens: t.tokens, space: t.harness.space, now: now.addingTimeInterval(61))
      guard case let .refused(response) = expired else { Issue.record("expired credential acted"); return }
      #expect(response.status == .unauthorized)
      #expect(try await response.body.text().contains("credentialExpired"))
      #expect(throws: OperationError.self) { try t.tokens.credential(session: t.parent, group: .shared, scope: "script", key: "exec", timeout: .seconds(300), now: now.addingTimeInterval(61), active: { true }) }
      active.withLock { $0 = false }
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      active.withLock { $0 = true }
      _ = try await t.harness.store.archive(t.parent, grace: .seconds(3600))
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .forbidden)
      #expect(throws: OperationError.self) {
        try t.tokens.credential(session: t.parent, group: .shared, scope: "script", key: "exec", timeout: .seconds(300), now: now.addingTimeInterval(ExecTokens.longestLife + 61), previouslyIssued: true, active: { true })
      }
      let restarted = ExecTokens(spaceURL: t.tokens.spaceURL)
      guard case .refused = await sessionVerdict(token, tokens: restarted, space: t.harness.space, now: now) else { Issue.record("forgotten token fell back"); return }
    }
  }

  @Test func v2CredentialLifecycleChecksDurableOperationAndOriginGroup() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let key = SymmetricKey(size: .bits256)
      let store = try await t.harness.space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
      let service = MachineV2Service(space: t.harness.space, hub: MachineV2Hub(space: t.harness.space), key: key, failure: nil, fetch: { _ in .init { _ in throw OperationError(.transport) } })
      let owner = OperationOwner(scope: "script", key: "exec")
      let credential = try await service.credential(tokens: t.tokens, session: t.parent, group: .shared, owner: owner, timeout: .seconds(60))
      let token = try #require(credential.object?["token"]?.stringValue)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      var record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "exec.v1", input: ["sessionCredential": credential]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))
      _ = try await store.claim(owner, record: record)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .ok)
      record.stopReason = "scriptEnded"; try await store.save(record, appending: nil)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      record.stopReason = nil; record.diagnostic = OperationError(.unknownOperation); try await store.save(record, appending: nil)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      record.diagnostic = nil; record.snapshot = .init(operation: record.id, verdict: .init(.completed, result: [:]), terminalToken: UUID(), finalOffsets: [:], outputConsumed: true); try await store.save(record, appending: nil)
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      let mismatch = try t.tokens.credential(session: t.parent, group: .init(rawValue: "another"), scope: "script", key: "other", timeout: .seconds(60), now: Date(), active: { true })
      #expect(try await t.harness.get("/v1/server", bearer: try #require(mismatch.object?["token"]?.stringValue)).status == .forbidden)
      await service.shutdown()
    }
  }
}

extension SessionGateTests {
  @Test func failedUnclaimedExecAttemptsCannotExhaustIssuerAndClaimedTombstonesRemain() throws {
    let tokens = ExecTokens(spaceURL: "https://test.invalid")
    let session = SessionID(rawValue: "test-session")
    let now = Date()
    for lifetime in [Duration.zero, .seconds(-1), .init(secondsComponent: 0, attosecondsComponent: 1)] {
      do {
        _ = try tokens.credential(session: session, group: .shared, scope: "invalid", key: String(describing: lifetime), timeout: lifetime, now: now, reserveAttempt: true, active: { false })
        Issue.record("invalid expiry reserved a credential")
      } catch let error as OperationError { #expect(error.code == .invalidInput) }
    }
    for index in 0 ... 65536 {
      let key = String(index)
      _ = try tokens.credential(session: session, group: .shared, scope: "failed", key: key, timeout: .seconds(60), now: now, reserveAttempt: true, active: { false })
      tokens.finishCredentialAttempt(session: session, group: .shared, scope: "failed", key: key, claimed: false)
    }
    let other = SessionID(rawValue: "unrelated-session")
    let credential = try tokens.credential(session: other, group: .shared, scope: "new", key: "exec", timeout: .seconds(60), now: now, reserveAttempt: true, active: { true })
    tokens.finishCredentialAttempt(session: other, group: .shared, scope: "new", key: "exec", claimed: true)
    #expect(tokens.v2Holder(ofBearer: credential.object!["token"]!.stringValue!) != nil)
    #expect(throws: OperationError.self) {
      try tokens.credential(session: other, group: .shared, scope: "new", key: "exec", timeout: .seconds(60), now: now.addingTimeInterval(61), active: { true })
    }
  }

  @Test func oneFailedAttemptCannotDiscardAConcurrentAttemptCredential() throws {
    let tokens = ExecTokens(spaceURL: "https://test.invalid")
    let session = SessionID(rawValue: "test-session")
    let now = Date()
    let credential = try tokens.credential(session: session, group: .shared, scope: "parallel", key: "exec", timeout: .seconds(60), now: now, reserveAttempt: true, active: { true })
    _ = try tokens.credential(session: session, group: .shared, scope: "parallel", key: "exec", timeout: .seconds(60), now: now, reserveAttempt: true, active: { true })
    tokens.finishCredentialAttempt(session: session, group: .shared, scope: "parallel", key: "exec", claimed: false)
    #expect(tokens.v2Holder(ofBearer: credential.object!["token"]!.stringValue!) != nil)
    tokens.finishCredentialAttempt(session: session, group: .shared, scope: "parallel", key: "exec", claimed: true)
    #expect(tokens.v2Holder(ofBearer: credential.object!["token"]!.stringValue!) != nil)
  }
}

// One request through the gate as a tool call: its status and body text,
// comparable across a retry.
private func toolCalled(
  _ harness: SessionHarness, bearer: String, _ method: Fetch.Method, _ path: String, _ body: JSONValue, toolCall: String,
) async throws -> (Status, String) {
  var request = Request(url: URL(string: "http://space\(path)")!, method: method)
  if body != .null {
    request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
  }
  request.headers[.authorization] = "Bearer " + bearer
  request.headers[ToolCallHeader.name] = toolCall
  let response = try await harness.api(request)
  return (response.status, try await response.text())
}
