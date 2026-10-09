import struct Credentials.CredentialResolver
import Fetch
import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private func discoveryScript(_ harness: SessionHarness, _ session: SessionID, _ source: String) async throws -> JSONValue {
  let scripts = harness.runtime.scripts
  let tools = ToolExecutor(space: harness.space, scripts: scripts)
  return try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await scripts.run() }
    defer { group.cancelAll() }
    let execution = scripts.start(source, session: session, lifetime: .seconds(30), tools: tools)
    let answer = try await execution.answer(within: .seconds(30), onTimeout: .kill)
    guard case let .result(text) = answer else {
      Issue.record("Discovery script failed: \(answer)")
      return .null
    }
    return try #require(JSONValue.parse(text))
  }
}

@Suite struct DiscoveryRouteTests {
  @Test(arguments: [false, true])
  func sessionHTTPAndModuleDiscoveryAgree(task: Bool) async throws {
    try await withSessionDeps {
      let tree = try await SessionGateTests().tree()
      let harness = tree.harness
      let session = task ? tree.child : tree.parent
      let machine = try #require(try await harness.space.resolveMachine("box", usableFrom: .shared))
      let record = try await harness.space.mintExec(machine: machine.id, caller: session.rawValue)
      let token = tree.tokens.credential(session: session, exec: record.id, timeout: nil, now: Date()).token
      let context = try await json(harness.get("/v1/context", bearer: token))
      let groups = try await json(harness.get("/v1/groups", bearer: token))
      let roster = try await json(harness.get("/v1/session-tools", bearer: token))
      let capability = try await json(harness.get("/v1/capabilities/image", bearer: token))
      let script = try await discoveryScript(harness, session, """
      import {context,groups} from 'wuhu:space'
      import {toolRoster} from 'wuhu:session'
      import {capability} from 'wuhu:ai'
      result({context:await context(),groups:await groups(),roster:await toolRoster(),capability:await capability('image')})
      """)
      #expect(script == .object(["context": context, "groups": groups, "roster": roster, "capability": capability]))
      #expect(context.object?["session"] == .string(session.rawValue))
      #expect(context.object?["group"] == "shared")
      #expect(roster.object?["rosters"]?.array?.map { $0.object?["executor"] } == ["kernel", "claude-code"])
      #expect(roster.object?["rosters"]?.array?.first?.object?["tools"]?.array?.contains { $0.object?["name"] == "bookmark" } == true)
    }
  }

  @Test(arguments: [false, true])
  func contentOriginUsesServerHostingConfiguration(flat: Bool) async throws {
    let harness = try Harness(origin: "https://space.test:5530", contentHostPattern: flat ? "{group}--space.test:5530" : nil)
    let response = try await harness.api(Request(url: URL(string: "https://space.test:5530/v1/context")!))
    #expect(response.status == .ok)
    let context = try await json(response)
    #expect(context == ["session": .null, "group": "shared", "contentHost": .string(flat ? "https://shared--space.test:5530" : "https://shared.space.test:5530")])
  }

  @Test func capabilityHTTPIsConfigurationOnlyAndDoesNotExposeCredentials() async throws {
    let seen = Mutex<[String]>([])
    let harness = try Harness(credentials: CredentialResolver { id in
      seen.withLock { $0.append(id) }
      return .chatGPT(accessToken: "private-token", accountID: "private-account")
    })
    _ = try await harness.space.fs(.shared).write("/capabilities.json", Data(#"{"image":{"active":"studio","providers":{"studio":{"dialect":"openai-images","credential":"private-id","model":"gpt-image-1","baseURL":"https://private-endpoint.test"}}}}"#.utf8), ifMatch: nil)
    let response = try await harness.get(harness.api, "/v1/capabilities/image")
    #expect(response.status == .ok)
    let value = try await json(response)
    #expect(value.object?["provider"] == "studio")
    #expect(value.object?["authentication"] == "not_checked")
    #expect(!value.jsonString().contains("private"))
    #expect(seen.withLock { $0.isEmpty })
    let invalid = try await harness.get(harness.api, "/v1/capabilities/no-such-kind")
    #expect(try await json(invalid).object?["code"] == "invalid_argument")
  }
}
