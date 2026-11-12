import struct Credentials.CredentialResolver
import DeterministicDependencies
import Fetch
import Foundation
import GRDB
import JSONValue
import MachineContract
import ServeTesting
import SessionDomain
import SpaceContract
import struct SpaceFS.SpacePath
import SpaceTools
@_spi(Testing) @testable import SpaceCore
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
    let harness = try await SessionHarness(dev: dev, credentials: credentials, spaceURL: "https://space.test:5530")
    let tokens = harness.runtime.tokens
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let parent = try await harness.store.createSession(group: .shared, title: "orchestrator", kind: .agent, createdBy: "owner", executor: model)
    let child = try await harness.store.createSession(
      group: .shared,
      title: "coder", kind: .task, parent: parent, createdBy: parent.rawValue, executor: model,
    )
    let stranger = try await harness.store.createSession(group: .shared, title: "stranger", kind: .agent, createdBy: "owner", executor: model)
    let machine = (try await harness.space.addMachineV2(name: "box")).machine
    let exec = try await harness.space.reserveExec(machine: machine.id, caller: parent.rawValue)
    let token = try await tokens.credential(session: parent, exec: exec.id, timeout: timeout, now: Date()).token
    return Tree(harness: harness, tokens: tokens, parent: parent, child: child, stranger: stranger, exec: exec.id, token: token)
  }

  // A task archives only itself and what it created; a top-level
  // agent is an admin of its group and archives any session in it.
  @Test func archivingNeedsTheSessionItsCreatorOrAnAdminOfItsGroup() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: .shared))
      let childExec = try await t.harness.space.reserveExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = try await t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
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
      try await until("archived") { try await t.harness.store.record(others).lifecycle != .live }
    }
  }

  @Test func tagsOnItsOwnChildWork() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let tagged = try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", .object(["tags": ["wuhu:37"]]), bearer: t.token)
      #expect(tagged.status == .ok)
      try await until("tagged") { try await t.harness.store.record(t.child).tags == ["wuhu:37"] }
    }
  }

  @Test func verbsOnlyTheWalletHasAreRefusedWithTheExactMessage() async throws {
    try await withSessionDeps {
      let t = try await tree()
      for (method, path) in [
        (Fetch.Method.get, "/v1/users"), (.get, "/v1/accounts"),
        (.post, "/v1/machine-v2"), (.get, "/v1/providers"), (.get, "/v1/session/\(t.child.rawValue)/lines/page"),
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

  @Test func tableHTTPWritesTakeAWriteRole() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let account = try await t.harness.space.addAccount(kind: .human, name: "reader")
      let group = try await t.harness.space.ensurePersonalGroup(account: account.id)
      let owner = GroupID(rawValue: "owner")
      try await t.harness.addGroup(owner)
      // owner's list admits the reader's group at read only.
      try await t.harness.space.setGrant(.group, group.rawValue, role: .read, in: owner, by: .anonymous, acting: owner)
      let reader = try await t.harness.store.createSession(group: group, title: "reader", kind: .agent, createdBy: "reader", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      let readerBox = (try await t.harness.space.addMachineV2(name: "reader_box", group: group)).machine
      let machine = try #require(try await t.harness.space.resolveMachine(readerBox.id.rawValue, usableFrom: group))
      let exec = try await t.harness.space.reserveExec(machine: machine.id, caller: reader.rawValue)
      let token = try await t.tokens.credential(session: reader, exec: exec.id, timeout: nil, now: Date()).token
      let path = "wuhu://owner.localspace/.agents/skills/test/data.table"
      let header: JSONValue = ["columns": [["name": "s", "type": "string"]]]
      let ownerSeat = SpaceToolContext(space: t.harness.space, principal: Principal(actor: .anonymous, group: owner))
      let created = try await SpaceToolbox.all.first { $0.name == "table.create" }!
        .run(ownerSeat, input: ["path": .string(path), "header": header])
      #expect(try await t.harness.post("/v1/tools/table.schema", ["path": .string(path)], bearer: token).status == .ok)
      for (verb, input) in [
        ("table.create", JSONValue.object(["path": .string("wuhu://owner.localspace/x.table"), "header": header])),
        ("table.alter", JSONValue.object(["path": .string(path), "header": header, "ifMatch": .string(created.object?["token"]?.stringValue ?? "")])),
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

      let machine = (try await t.harness.space.addMachineV2(name: "box2")).machine
      let childExec = try await t.harness.space.reserveExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = try await t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
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
      let childExec = try await t.harness.space.reserveExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = try await t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token
      _ = try await t.harness.store.openRequest(on: t.child, from: .session(t.parent), messageID: .init("ask-1"), text: "work")
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
      #expect(try await pendingTimers(t.harness, t.parent) == [timer.id])
      let both = try await t.harness.post(
        "/v1/subscription", .object(["timer": ["message": "x", "inSeconds": 1], "observe": ["sql": "SELECT 1"]]), bearer: t.token,
      )
      #expect(both.status == .badRequest)
      var cancel = Request(url: URL(string: "http://space/v1/subscription/\(timer.id)")!, method: .delete)
      cancel.headers[.authorization] = "Bearer " + t.token
      let ended = try await t.harness.api(cancel)
      #expect(ended.status == .ok)
      #expect(try await ended.text().contains(timer.id))
      #expect(try await pendingTimers(t.harness, t.parent).isEmpty)
      #expect(try await t.harness.api(cancel).status == .unprocessableContent)

      let titled = try await t.harness.call(
        "/v1/session/\(t.parent.rawValue)/title", .object(["title": "lead"]), as: SessionTitleOutput.self, bearer: t.token,
      )
      #expect(titled.title == "lead")
      try await until("retitled") { try await t.harness.store.record(t.parent).title == "lead" }
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
      let timers = try await pendingTimers(t.harness, t.parent)
      #expect(timers.count == 1)
      let id = try #require(timers.first)

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
      #expect(try await call(.delete, "/v1/subscription/\(goneID)", .null, toolCall: "tc-timer-gone-cancel").0 == .ok)
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
      let timers = try await pendingTimers(t.harness, t.parent)
      #expect(timers.count == 1)
      let id = try #require(timers.first)

      async let firstCancel = call(.delete, "/v1/subscription/\(id)", .null, "tc-cancel")
      async let secondCancel = call(.delete, "/v1/subscription/\(id)", .null, "tc-cancel")
      let cancelled = try await (firstCancel, secondCancel)
      #expect(cancelled.0.0 == .ok)
      #expect(cancelled.0 == cancelled.1)
      #expect(try await pendingTimers(t.harness, t.parent).isEmpty)

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

  // A retry of a request or a report is the first one again.
  @Test func aRetriedRequestOrReportIsTheFirstOne() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.resolveMachine("box", usableFrom: .shared))
      let childExec = try await t.harness.space.reserveExec(machine: machine.id, caller: t.child.rawValue)
      let childToken = try await t.tokens.credential(session: t.child, exec: childExec.id, timeout: nil, now: Date()).token

      let ask: JSONValue = .object(["message": "do it", "stallSeconds": 30])
      let opened = try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session/\(t.child.rawValue)/request", ask, toolCall: "tc-ask")
      #expect(opened.0 == .ok)
      #expect(try await toolCalled(t.harness, bearer: t.token, .post, "/v1/session/\(t.child.rawValue)/request", ask, toolCall: "tc-ask") == opened)
      let requestID = try #require(JSONValue.parse(opened.1)?.object?["requestId"]?.stringValue)

      _ = try await t.harness.store.drainQueue(t.child)
      let done: JSONValue = .object(["kind": "final", "content": "done"])
      let reported = try await toolCalled(t.harness, bearer: childToken, .post, "/v1/request/\(requestID)/report", done, toolCall: "tc-done")
      #expect(reported.0 == .ok)
      #expect(try await toolCalled(t.harness, bearer: childToken, .post, "/v1/request/\(requestID)/report", done, toolCall: "tc-done") == reported)
      let conversation = try #require(JSONValue.parse(reported.1)?.object?["conversationId"]?.stringValue)
      let finals = try await t.harness.store.messages(conversation: ConversationID(conversation)).filter { $0.kind == .final }
      #expect(finals.count == 1)
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
      try await withExecDescription(space: t.harness.space, hub: t.harness.hub, machine: machine.id) {
        let others = try await t.harness.space.reserveExec(machine: machine.id)
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
  }

  @Test func toolExecStatusAndListExposeTheToolCall() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.machine(named: "box"))
      let first = try await t.harness.space.reserveExec(machine: machine.id, caller: t.parent.rawValue, group: .shared, toolCall: ToolCallID(rawValue: "claim"))
      let response = try await t.harness.get("/v1/exec/\(first.id.rawValue)", bearer: t.token)
      let status = try JSONValueDecoder().decode(ExecStatus.self, from: #require(JSONValue.parse(try await response.text())))
      #expect(status.toolCallID == "claim")
      let listed = try await t.harness.get("/v1/exec", bearer: t.token)
      let statuses = try JSONValueDecoder().decode([ExecStatus].self, from: #require(JSONValue.parse(try await listed.text())))
      #expect(statuses.filter { $0.toolCallID == "claim" }.map(\.id) == [first.id])
    }
  }

  @Test func killingAnEndedOwnExecIsAlreadyEnded() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.machine(named: "box"))
      let ended = try await t.harness.space.reserveExec(machine: machine.id, caller: t.parent.rawValue)
      try await setExecTerminalFixture(space: t.harness.space, exec: ended.id, terminal: .exited(code: 0))
      let response = try await t.harness.post("/v1/exec/\(ended.id.rawValue)/kill", .null, bearer: t.token)
      #expect(response.status == .unprocessableContent)
      let body = try await response.text()
      #expect(JSONValue.parse(body)?.object?["code"]?.stringValue == "alreadyEnded")
    }
  }

  // The gate's webSocket catch-all is registered before the exec route; the
  // exec route must still win for the session's own exec.
  @Test func itsOwnExecDialsOverWebSocketAndNothingElseDoes() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let machine = try #require(try await t.harness.space.machine(named: "box"))
      try await withExecDescription(space: t.harness.space, hub: t.harness.hub, machine: machine.id) {
        let others = try await t.harness.space.reserveExec(machine: machine.id)

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
          case let .webSocket(socket, _): socket.close(); return nil
          }
        }

        #expect(try await dial("/v1/exec/\(t.exec.rawValue)") == nil)
        #expect(try await dial("/v1/exec/\(others.id.rawValue)") == .notFound)
        #expect(try await dial("/v1/sessions/\(t.parent.rawValue)/stream") == .forbidden)
        #expect(try await dial("/v1/anything") == .forbidden)
      }
    }
  }

  @Test func aTokenStopsWorkingWhenItsExecEndsOrItExpires() async throws {
    try await withSessionDeps {
      let t = try await tree(timeout: 60)
      #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .ok)

      let unknown = try await t.harness.get("/v1/server", bearer: ExecTokens.prefix + String(repeating: "0", count: 64))
      #expect(unknown.status == .unauthorized)

      try await setExecTerminalFixture(space: t.harness.space, exec: t.exec, terminal: .exited(code: 0))
      let ended = try await t.harness.get("/v1/server", bearer: t.token)
      #expect(ended.status == .unauthorized)
      #expect(try await ended.text().contains("ended"))
    }
  }

  @Test func machineLossEndsTheToken() async throws {
    try await withSessionDeps {
      let t = try await tree(timeout: 60)
      try await setExecTerminalFixture(space: t.harness.space, exec: t.exec, terminal: .machineLost)
      #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .unauthorized)
    }
  }

  @Test func cancelledAndReapedExecsEndTheToken() async throws {
    try await withSessionDeps {
      for state in [ExecTerminalState.cancelled, .reaped] {
        let t = try await tree(timeout: 60)
        try await setExecTerminalFixture(space: t.harness.space, exec: t.exec, terminal: state)
        #expect(try await t.harness.get("/v1/server", bearer: t.token).status == .unauthorized)
      }
    }
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

extension SessionGateTests {
  @Test func signedCredentialsKeepSessionAuthorityAndExpire() async throws {
    try await withSessionDeps {
      let t = try await tree(dev: false)
      let now = Date()
      let token = try await t.tokens.credential(session: t.parent, exec: t.exec, timeout: 60, now: now).token
      #expect(token.hasPrefix(ExecTokens.prefix))
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .ok)
      #expect(try await t.harness.post("/v1/session/\(t.child.rawValue)/tags", ["tags": ["signed"]], bearer: token).status == .ok)
      #expect(try await t.harness.get("/v1/users", bearer: token).status == .forbidden)
      #expect(try await t.harness.get("/v1/server?group=another", bearer: token).status == .forbidden)
      let expired = await sessionVerdict(token, tokens: t.tokens, space: t.harness.space, now: now.addingTimeInterval(61))
      guard case let .refused(response) = expired else { Issue.record("expired credential acted"); return }
      #expect(response.status == .unauthorized)
      #expect(try await response.body.text().contains("credentialExpired"))
      _ = try await t.harness.store.archive(t.parent, grace: .seconds(3600))
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .forbidden)
    }
  }

  @Test func signedCredentialLifecycleChecksDurableExecAndOriginGroup() async throws {
    try await withSessionDeps {
      let t = try await tree()
      let record = try #require(try await t.harness.space.execRecord(t.exec))
      let missing = try await t.tokens.credential(session: t.parent, group: .shared, machine: record.machine, exec: ExecID(rawValue: "ex_00000000"), timeout: .seconds(60), issuedAt: Date())
      #expect(try await t.harness.get("/v1/server", bearer: try #require(missing.object?["token"]?.stringValue)).status == .unauthorized)
      let token = try await t.tokens.credential(session: t.parent, exec: t.exec, timeout: 60, now: Date()).token
      #expect(try await t.harness.get("/v1/server", bearer: token).status == .ok)
      let mismatch = try await t.tokens.credential(session: t.parent, group: .init(rawValue: "another"), machine: record.machine, exec: t.exec, timeout: .seconds(60), issuedAt: Date())
      #expect(try await t.harness.get("/v1/server", bearer: try #require(mismatch.object?["token"]?.stringValue)).status == .forbidden)
      for terminal in [ExecTerminalState.cancelled, .machineLost, .exited(code: 0)] {
        try await setExecTerminalFixture(space: t.harness.space, exec: t.exec, terminal: terminal)
        #expect(try await t.harness.get("/v1/server", bearer: token).status == .unauthorized)
      }
    }
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

private func pendingTimers(_ harness: SessionHarness, _ session: SessionID) async throws -> [String] {
  _ = try await harness.store.sent(session)
  return try await harness.space.writer.read { db in
    try String.fetchAll(
      db,
      sql: """
      SELECT q.topic FROM session_queue q JOIN session_runtime r ON r.session_id = q.session_id
      WHERE q.session_id = ? AND q.id > r.queue_tail AND q.topic LIKE 'timer.%' ORDER BY q.id
      """,
      arguments: [session.rawValue],
    )
  }
}
