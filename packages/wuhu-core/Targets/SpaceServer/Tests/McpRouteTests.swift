import Assertion
import struct Credentials.CredentialResolver
import Crypto
import Dependencies
import Fetch
import Foundation
import JSONValue
import struct SessionDomain.ModelSpecifier
import enum SessionDomain.SessionExecutor
import SessionTools
import SpaceContract
import SpaceCore
import SpaceServer
import Synchronization
import Testing

extension JSONValue {
  fileprivate subscript(key: String) -> JSONValue? {
    guard case let .object(fields) = self else { return nil }
    return fields[key]
  }

  fileprivate var text: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }
}

@Suite struct McpRouteTests {
  @Test func initializeNegotiatesEveryAcceptedProtocolVersion() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue

      for requested in ["2025-06-18", "2025-03-26", "2024-11-05"] {
        let response = try await harness.post(
          "/v1/session/\(session)/mcp",
          rpc("initialize", params: .object([
            "protocolVersion": .string(requested),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("probe"), "version": .string("1")]),
          ])),
        )
        #expect(response.status == .ok)
        let result = try await envelope(response)["result"]
        #expect(result?["protocolVersion"]?.text == requested)
        #expect(result?["serverInfo"]?["name"]?.text == "wuhu")
        #expect(result?["serverInfo"]?["version"]?.text == SpaceServer.unstampedVersion)
        #expect(result?["capabilities"]?["tools"] == .object([:]))
      }

      let ancient = try await harness.post(
        "/v1/session/\(session)/mcp",
        rpc("initialize", params: .object(["protocolVersion": .string("2020-01-01")])),
      )
      #expect(try await envelope(ancient)["result"]?["protocolVersion"]?.text == "2025-06-18")

      let silent = try await harness.post("/v1/session/\(session)/mcp", rpc("initialize"))
      #expect(try await envelope(silent)["result"]?["protocolVersion"]?.text == "2025-06-18")
    }
  }

  @Test func toolsListIsExactlyTheClaudeCodeRoster() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      let response = try await harness.post("/v1/session/\(session)/mcp", rpc("tools/list"))
      #expect(response.status == .ok)
      guard case let .array(tools)? = try await envelope(response)["result"]?["tools"] else {
        Issue.record("tools/list did not return an array")
        return
      }
      let roster = SessionToolExecutor.claudeCode.tools.map { tool in
        guard case let .function(name, description, parameters) = tool else {
          preconditionFailure("MCP roster contains a hosted tool")
        }
        return (name, description, parameters)
      }
      #expect(tools.compactMap { $0["name"]?.text } == roster.map(\.0))
      for (listed, roster) in zip(tools, roster) {
        #expect(listed["description"]?.text == roster.1)
        #expect(listed["inputSchema"] == roster.2)
        // Claude Code keeps a result this long inline instead of saving it to a file.
        #expect(listed["_meta"]?["anthropic/maxResultSizeChars"] == .integer(500_000))
      }
    }
  }

  @Test func toolCallsRunTheKernelExecutorAsTheSession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      _ = try await harness.space.fs(.shared).write("/hello.md", Data("first line\nsecond line\n".utf8), ifMatch: nil)

      let read = try await callResult(harness, session, tool: "read", .object(["path": .string("/hello.md")]))
      #expect(read["isError"] == .bool(false))
      #expect(resultText(read)?.contains("first line") == true)

      let query = try await callResult(
        harness, session, tool: "query",
        .object(["sql": .string("SELECT id FROM sessions")]),
      )
      #expect(query["isError"] == .bool(false))
      #expect(resultText(query)?.contains(session) == true)

      let asked = try await harness.call(
        "/v1/conversation/message",
        .object(["message": .string("what is up"), "session": .string(session)]),
        as: ConversationPostOutput.self,
      )
      let replied = try await callResult(
        harness, session, tool: "send_message",
        .object(["message": .string("all clear"), "reply_target": .string(asked.messageId)]),
      )
      #expect(replied["isError"] == .bool(false))
      #expect(resultText(replied)?.contains(session) == true)

      let page = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try #require(JSONValue.parse(try await harness.get("/v1/conversation/\(session)/messages").text())),
      )
      #expect(page.messages.map(\.text).contains("all clear"))
      #expect(page.messages.last?.senderSession == session)
    }
  }

  @Test func aSessionCanGenerateAnImageThroughMCP() async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let harness = try await SessionHarness(credentials: CredentialResolver { providerID in
        providerID == "codex" ? .chatGPT(accessToken: "token", accountID: "account") : nil
      })
      _ = try await harness.space.fs(.shared).write("/models.json", Data(mcpImageModels.utf8), ifMatch: nil)
      let session = try await harness.store.createSession(
        group: .shared,
        title: "image",
        kind: .agent,
        createdBy: "morgan",
        executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      ).rawValue

      let generated = try await withDependencies {
        $0.fetch = FetchClient { request in
          #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/codex/images/generations")
          requests.withLock { $0 += 1 }
          return Response(
            status: .ok,
            body: .string(#"{"data":[{"b64_json":"\#(mcpImagePNG.base64EncodedString())"}]}"#),
          )
        }
      } operation: {
        try await callResult(
          harness, session, tool: "generate_image",
          .object(["prompt": .string("a moon"), "destination": .string("/art/moon.png")]),
        )
      }

      #expect(generated["isError"] == .bool(false))
      let text = try #require(resultText(generated))
      #expect(text == "wrote /art/moon.png")
      #expect(try await harness.space.fs(.shared).read("/art/moon.png").1 == mcpImagePNG)
      #expect(requests.withLock { $0 } == 1)
    }
  }

  @Test func aFailingToolIsAResultWithIsErrorSet() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      let missing = try await callResult(harness, session, tool: "read", .object(["path": .string("/nope.md")]))
      #expect(missing["isError"] == .bool(true))
      #expect(resultText(missing)?.isEmpty == false)
    }
  }

  @Test func writeAfterReadCarriesTheExecutorStateAcrossRequests() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      _ = try await harness.space.fs(.shared).write("/notes.md", Data("one\n".utf8), ifMatch: nil)

      let blind = try await callResult(
        harness, session, tool: "write",
        .object(["path": .string("/notes.md"), "content": .string("two\n")]),
      )
      #expect(blind["isError"] == .bool(true), "an unread overwrite must fail exactly as it does in the kernel loop")

      _ = try await callResult(harness, session, tool: "read", .object(["path": .string("/notes.md")]))
      let informed = try await callResult(
        harness, session, tool: "write",
        .object(["path": .string("/notes.md"), "content": .string("two\n")]),
      )
      #expect(informed["isError"] == .bool(false))
      let (_, data) = try await harness.space.fs(.shared).read("/notes.md")
      #expect(String(decoding: data, as: UTF8.self) == "two\n")
    }
  }

  @Test func aRestartRetiresTheReadLogTheOldGenerationEarned() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let session = id.rawValue
      _ = try await harness.space.fs(.shared).write("/notes.md", Data("one\n".utf8), ifMatch: nil)
      _ = try await callResult(harness, session, tool: "read", .object(["path": .string("/notes.md")]))

      _ = try await harness.call("/v1/session/\(session)/restart", .null, as: SessionRestartOutput.self)

      let blind = try await callResult(
        harness, session, tool: "write",
        .object(["path": .string("/notes.md"), "content": .string("two\n")]),
      )
      #expect(
        blind["isError"] == .bool(true),
        "a read the wiped generation did is no proof the fresh one read anything",
      )
    }
  }

  @Test func aLaterGenerationCancelsTheSubscriptionsAnEarlierOneArmed() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let claudeCode = SessionExecutor.claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high"))
      let id = try await harness.store.createSession(group: .shared, title: "cc", kind: .agent, createdBy: "morgan", executor: claudeCode)
      let other = try await harness.store.createSession(group: .shared, title: "other", kind: .agent, createdBy: "morgan", executor: claudeCode)
      let session = id.rawValue

      let timer = try await callResult(
        harness, session, tool: "timer",
        .object(["message": .string("tick"), "cron": .string("*/40 * * * *")]), toolUseID: "toolu_timer",
      )
      let observation = try await callResult(
        harness, session, tool: "observe",
        .object(["sql": .string("SELECT id FROM sessions")]), toolUseID: "toolu_observe",
      )
      #expect(timer["isError"] == .bool(false))
      #expect(observation["isError"] == .bool(false))

      try await harness.store.appendClaudeCodeMirror(id, entries: [
        ["type": "system", "subtype": "compact_boundary", "uuid": "b1", "compactMetadata": ["trigger": "auto"]],
      ])
      #expect(try await harness.store.generationState(id).generation == 1)

      let stranger = try await callResult(
        harness, other.rawValue, tool: "cancel_timer", .object(["subscription_id": "timer.toolu_timer"]),
      )
      #expect(stranger["isError"] == .bool(true), "a session owns only the subscriptions it armed")

      let wrongKind = try await callResult(
        harness, session, tool: "cancel_observation", .object(["subscription_id": "timer.toolu_timer"]),
      )
      #expect(resultText(wrongKind)?.contains("cancel_timer") == true)

      let cancelledTimer = try await callResult(
        harness, session, tool: "cancel_timer", .object(["subscription_id": "timer.toolu_timer"]),
      )
      #expect(cancelledTimer["isError"] == .bool(false), Comment(rawValue: resultText(cancelledTimer) ?? ""))
      let cancelledObservation = try await callResult(
        harness, session, tool: "cancel_observation", .object(["subscription_id": "obs.toolu_observe"]),
      )
      #expect(cancelledObservation["isError"] == .bool(false), Comment(rawValue: resultText(cancelledObservation) ?? ""))
      #expect(try await harness.store.armedSubscriptions(id).isEmpty)
    }
  }

  @Test func transportEdgesFollowTheStreamableHTTPContract() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      let path = "/v1/session/\(session)/mcp"

      #expect(try await harness.get(path).status == .methodNotAllowed)

      let delete = Request(url: URL(string: "http://space\(path)")!, method: .delete)
      #expect(try await harness.api(delete).status == .noContent)

      let notification = try await harness.post(
        path, .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
      )
      #expect(notification.status == .accepted)
      #expect(try await notification.text() == "")

      let cancelled = try await harness.post(
        path,
        .object([
          "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
          "params": .object(["requestId": .integer(7)]),
        ]),
      )
      #expect(cancelled.status == .accepted)

      let ping = try await harness.post(path, rpc("ping", id: .string("p1")))
      #expect(ping.status == .ok)
      let pinged = try await envelope(ping)
      #expect(pinged["id"] == .string("p1"))
      #expect(pinged["result"] == .object([:]))

      let unknown = try await harness.post(path, rpc("resources/list"))
      #expect(unknown.status == .ok)
      #expect(try await envelope(unknown)["error"]?["code"] == .integer(-32601))

      var malformed = Request(url: URL(string: "http://space\(path)")!, method: .post)
      malformed.body = .bytes(Data("{not json".utf8), contentType: "application/json")
      let parsed = try await harness.api(malformed)
      #expect(parsed.status == .badRequest)
      #expect(try await envelope(parsed)["error"]?["code"] == .integer(-32700))

      let batch = try await harness.post(path, .array([rpc("ping"), rpc("tools/list", id: .integer(2))]))
      #expect(batch.status == .badRequest)
      #expect(try await envelope(batch)["error"]?["code"] == .integer(-32600))

      let namelessCall = try await harness.post(path, rpc("tools/call", params: .object(["arguments": .object([:])])))
      #expect(try await envelope(namelessCall)["error"]?["code"] == .integer(-32602))

      let strangeTool = try await harness.post(
        path, rpc("tools/call", params: .object(["name": .string("rm_rf"), "arguments": .object([:])])),
      )
      #expect(try await envelope(strangeTool)["error"]?["code"] == .integer(-32602))
    }
  }

  @Test func unknownAndArchivedSessionsAreRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      #expect(try await harness.post("/v1/session/nope/mcp", rpc("tools/list")).status == .notFound)

      let session = try await harness.createSession().rawValue
      _ = try await harness.post("/v1/session/\(session)/archive", .null)
      let archived = try await harness.post("/v1/session/\(session)/mcp", rpc("tools/list"))
      #expect(archived.status == .conflict)
    }
  }

  @Test func onlyAnAdminSeatMayActAsAnArbitrarySession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      let space = try await harness.space.identity().rawValue

      func bearer(admin: Bool) async throws -> String {
        let key = Curve25519.Signing.PrivateKey()
        let account = try await harness.space.addAccount(kind: .human, name: nil, admin: admin)
        _ = try await harness.space.addKey(
          key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil,
        )
        return try AssertionClaims(
          key: key.pubkeyLabel, space: space, expiresAt: Date().addingTimeInterval(3600),
        ).signed(by: key).rawValue
      }

      let refused = try await harness.post(
        "/v1/session/\(session)/mcp", rpc("tools/list"), bearer: try await bearer(admin: false),
      )
      #expect(refused.status == .forbidden)
      #expect(try await envelope(refused)["code"] == .string("adminRequired"))

      let allowed = try await harness.post(
        "/v1/session/\(session)/mcp", rpc("tools/list"), bearer: try await bearer(admin: true),
      )
      #expect(allowed.status == .ok)
    }
  }
}
