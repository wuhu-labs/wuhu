import struct Credentials.CredentialResolver
import Fetch
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceContract
@testable import SpaceCore
import SpaceTools
import Testing
import enum WuhuAI.Tool

@Suite struct ScriptDiscoveryTests {
  @Test(arguments: ["root", "child", "task"])
  func callerContextAndGroupStandingMatchCheckedService(kind: String) async throws {
    let alice = GroupID(rawValue: "alice")
    try await withRig(group: alice, task: kind == "task", childAgent: kind == "child") { rig in
      try await rig.space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('hidden', '2026-01-01T00:00:00.000Z')")
      }
      for host in ["https://{group}.space.test:443", "https://{group}--tenant.space.test"] {
        rig.scripts.configureDiscovery(contentHost: host)
        let principal = try await rig.space.principal(of: rig.session)
        let service = SpaceToolContext(space: rig.space, principal: principal)
        let expectedContext = try await service.discoveryContext(contentHost: host)
        let expectedGroups = try JSONValueEncoder().encode(try await service.discoveryGroups())
        let actual = try await rig.evaluate("""
        import {context,groups} from 'wuhu:space'
        result({context:await context(),groups:await groups()})
        """)
        #expect(actual == .object(["context": expectedContext, "groups": expectedGroups]))
        #expect(actual.object?["context"]?.object?["session"] == .string(rig.session.rawValue))
        #expect(actual.object?["context"]?.object?["group"] == "alice")
        #expect(expectedGroups.array?.first { $0.object?["id"] == "hidden" } == ["id": "hidden", "member": false, "readable": false])
        #expect(expectedGroups.array?.first { $0.object?["id"] == "shared" } == ["id": "shared", "member": false, "readable": true])
      }
      let forgedGroup = SpaceToolContext(space: rig.space, principal: Principal(actor: .session(rig.session), group: .shared))
      #expect(try await forgedGroup.discoveryContext(contentHost: nil).object?["group"] == "alice")
      try await rig.space.addEdge(src: alice, dst: GroupID(rawValue: "hidden"), kind: .read, by: nil)
      let changed = try await rig.evaluate("import {groups} from 'wuhu:space';result((await groups()).find(x=>x.id==='hidden'))")
      #expect(changed == ["id": "hidden", "member": false, "readable": true])
    }
  }

  @Test func rosterIsTheConfiguredRuntimeDeclaration() async throws {
    try await withRig { rig in
      let missing = try await rig.evaluate("import {toolRoster} from 'wuhu:session';try {await toolRoster()} catch(e) {result({name:e.name,code:e.code})}")
      #expect(missing == ["name": "SpaceError", "code": "unsupported"])
      let roster = ToolRostersOutput(rosters: [.init(executor: .claudeCode, tools: ToolExecutor.tools.map {
        guard case let .function(name, description, parameters) = $0 else { preconditionFailure() }
        return ToolDescriptor(name: name, description: description, parameters: parameters)
      })])
      rig.scripts.configureDiscovery(toolRosters: roster)
      #expect(try await rig.evaluate("import {toolRoster} from 'wuhu:session';result(await toolRoster())") == JSONValueEncoder().encode(roster))
      let context = try await rig.evaluate("import {context} from 'wuhu:space';result(await context())")
      #expect(context.object?["contentHost"] == .null)
    }
  }

  @Test func capabilityProbeNeverResolvesCredentialsOrCallsAProvider() async throws {
    let credentials = Box<[String]>([])
    let requests = Box(0)
    try await withRig(fetch: FetchClient { _ in
      requests.withLock { $0 += 1 }
      return Response(status: .internalServerError)
    }, credentials: CredentialResolver { name in
      credentials.withLock { $0.append(name) }
      return nil
    }) { rig in
      let defaultProbe = try await rig.evaluate("import {capability} from 'wuhu:ai';result(await capability('image'))")
      #expect(defaultProbe.object?["provider"] == "codex")
      #expect(defaultProbe.object?["authentication"] == "not_checked")
      try await rig.write("/capabilities.json", #"{"image":{"active":"studio","providers":{"studio":{"dialect":"openai-images","credential":"private-account-secret","baseURL":"https://private.example/key-in-url","model":"gpt-image-1"}}},"transcription":{"active":"asr","providers":{"asr":{"dialect":"dashscope","model":"qwen-audio-3.1-asr-flash-filetrans"}}},"web_search":{"active":"lookup","providers":{"lookup":{"dialect":"brave"}}}}"#)
      let selected = try await rig.evaluate("""
      import {capability} from 'wuhu:ai'
      result(await Promise.all(['image','transcription','web_search'].map(capability)))
      """)
      #expect(selected.array?[0].object?["provider"] == "studio")
      #expect(selected.array?[0].object?["features"]?.object?["edit"] == true)
      #expect(selected.array?[1].object?["features"]?.object?["timestamps"] == ["words", "segments"])
      #expect(selected.array?[2].object?["dialect"] == "brave")
      #expect(!selected.jsonString().contains("private"))
      #expect(requests.value == 0)
      #expect(credentials.value.isEmpty)
      let invalid = try await rig.evaluate("""
      import {capability} from 'wuhu:ai'
      const errors=[]
      for (const kind of ['unknown',null,42]) { try {await capability(kind)} catch(e) {errors.push([e.name,e.code])} }
      result(errors)
      """)
      #expect(invalid == [["CapabilityError", "invalid_argument"], ["CapabilityError", "invalid_argument"], ["CapabilityError", "invalid_argument"]])
    }
  }

  @Test(arguments: [
    #"{"image":{"active":"missing","providers":{}}}"#,
    #"{"image":{"active":"broken","providers":{"broken":{"dialect":"brave"}}}}"#,
    #"{"image":{"active":"broken","providers":{"broken":{"dialect":"openai-images","baseURL":"https://user:password@example.test"}}}}"#,
    "not json",
  ])
  func brokenExplicitCapabilityNeverFallsBack(document: String) async throws {
    let credentials = Box(0)
    try await withRig(credentials: CredentialResolver { _ in credentials.withLock { $0 += 1 }; return nil }) { rig in
      try await rig.write("/capabilities.json", document)
      let result = try await rig.evaluate("import {capability} from 'wuhu:ai';try {await capability('image')} catch(e) {result({name:e.name,code:e.code})}")
      #expect(result == ["name": "CapabilityError", "code": "provider_not_configured"])
      #expect(credentials.value == 0)
    }
  }
}
