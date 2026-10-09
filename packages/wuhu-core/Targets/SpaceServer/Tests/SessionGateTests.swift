import struct Credentials.CredentialResolver
import Fetch
import Foundation
import JSONValue
import MachineContract
import ServeTesting
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// A session's exec token through the real handler: what it may do, as whom,
// and when it stops working.
@Suite struct SessionGateTests {
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
