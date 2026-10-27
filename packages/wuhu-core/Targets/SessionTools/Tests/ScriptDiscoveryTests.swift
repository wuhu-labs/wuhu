import struct Credentials.CredentialResolver
import Crypto
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import SpaceTools
import Testing

@Suite(.deterministicDependencies) struct ScriptDiscoveryTests {
  @Test(arguments: ["root", "child", "task"], ["{group}.space.test", "{group}--tenant.space.test"])
  func callerContextAndGroupStandingMatchCheckedService(kind: String, host: String) async throws {
    let alice = GroupID(rawValue: "alice")
    try await withRig(contentHost: host, group: alice, task: kind == "task", childAgent: kind == "child") { rig in
      try await rig.space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('hidden', '2026-01-01T00:00:00.000Z')")
      }
      let principal = try await rig.space.principal(of: rig.session)
      let service = SpaceToolContext(space: rig.space, principal: principal)
      let expectedContext = try await service.discoveryContext(contentHost: "https://" + host)
      let expectedGroups = try JSONValueEncoder().encode(try await service.discoveryGroups())
      let actual = try await rig.evaluate("""
      import {context,groups} from 'wuhu:space'
      result({context:await context(),groups:await groups()})
      """)
      #expect(actual == .object(["context": expectedContext, "groups": expectedGroups]))
      #expect(actual.object?["context"]?.object?["session"] == .string(rig.session.rawValue))
      #expect(actual.object?["context"]?.object?["group"] == "alice")
      #expect(expectedGroups.array?.first { $0.object?["id"] == "hidden" } == ["id": "hidden", "member": false, "readable": false, "admin": false])
      #expect(expectedGroups.array?.first { $0.object?["id"] == "shared" } == ["id": "shared", "member": false, "readable": true, "admin": false])
      let forgedGroup = SpaceToolContext(space: rig.space, principal: Principal(actor: .session(rig.session), group: .shared))
      #expect(try await forgedGroup.discoveryContext(contentHost: nil).object?["group"] == "alice")
      let hidden = GroupID(rawValue: "hidden")
      try await rig.space.setGrant(.group, alice.rawValue, role: .write, in: hidden, by: .anonymous, acting: hidden)
      let changed = try await rig.evaluate("import {groups} from 'wuhu:space';result((await groups()).find(x=>x.id==='hidden'))")
      #expect(changed == ["id": "hidden", "member": false, "readable": true, "admin": false])
    }
  }

  @Test func createGroupAssignsOnlyTheLiveMemberOwnerAndReturnsAReachableAlias() async throws {
    try await withRig { rig in
      let owner = try await rig.space.addAccount(kind: .human, name: "Morgan")
      let guest = try await rig.space.addAccount(kind: .human, name: "Guest", guest: true)
      let key = try await rig.space.addKey("ed25519:" + Data(repeating: 42, count: 32).base64EncodedString(), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let persona = try await rig.space.adoptPersona(key: key)
      _ = try await rig.space.setUserProfile(principal: persona.name, handle: "morgan", displayName: nil)
      let actual = try await rig.evaluate("""
      import {createGroup, groups, context, writeText, readText} from 'wuhu:space'
      const created = await createGroup({alias:'research_notes',owner:'morgan'})
      await writeText(`wuhu://${created.alias}.localspace/probe.md`, 'created', {ifMatch:null})
      const errors=[]
      for (const input of [{alias:'guest_space',owner:'\(guest.id.rawValue)'},{alias:'research_notes',owner:'\(owner.id.rawValue)'},{alias:'missing_owner'}]) {
        try { await createGroup(input) } catch(e) { errors.push(e.code) }
      }
      result({created, standing:(await groups()).find(g=>g.id===created.id), text:(await readText(`wuhu://${created.id}.localspace/probe.md`)).content, errors})
      """)
      let id = try #require(actual.object?["created"]?.object?["id"]?.stringValue)
      let group = GroupID(rawValue: id)
      #expect(actual.object?["text"] == "created")
      #expect(actual.object?["errors"] == ["memberRequired", "aliasTaken", "invalidArgument"])
      #expect(actual.object?["standing"] == ["id": .string(id), "member": false, "readable": true, "admin": false])
      #expect(try await rig.space.isHumanAdmin(owner.id, of: group))
      #expect(try await rig.space.group(group)?.visibility == .open)
      #expect(try await rig.space.resolveGroup("research_notes") == group)
    }
  }

  @Test func moduleImportsResolveCurrentAndRetiredGroupAliases() async throws {
    try await withRig(prepare: { space, _ in
      let owner = try await space.addAccount(kind: .human, name: "Morgan")
      let group = try await space.createGroup(alias: "library", owner: owner.id)
      _ = try await space.fs(group).write("/answer.js", Data("export const answer = 42".utf8), ifMatch: nil)
    }) { rig in
      #expect(try await rig.evaluate("import {answer} from 'wuhu://library.localspace/answer.js'; result(answer)") == 42)
      let group = try #require(try await rig.space.resolveGroup("library"))
      try await rig.space.renameGroup(group, alias: "modules", by: .shared(.anonymous))
      for alias in ["library", "modules", group.rawValue] {
        #expect(try await rig.evaluate("import {answer} from 'wuhu://\(alias).localspace/answer.js'; result(answer)") == 42)
      }
    }
  }

  @Test func identityIsReadOnlyAndResolvesCanonicalOrigins() async throws {
    let id = String(repeating: "o", count: 32)
    let controller = try IdentityController(
      identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), origin: "https://space.test",
      settings: .init(defaultIssuer: .directory, overrides: ["https://lab.test": .self], directoryID: id),
      store: .init(load: { nil }, save: { _ in }), fetch: FetchClient { _ in Response(status: .forbidden) },
    )
    try await withRig(identity: controller) { rig in
      let resolved = try await rig.evaluate("import {identity} from 'wuhu:space'; const i=await identity(); result([i.defaultIssuer,i.issuerFor('https://LAB.test:443'),i.issuerFor('https://cloud.test')])")
      #expect(resolved == [.string("https://id.wuhu.ai/" + id), "https://space.test", .string("https://id.wuhu.ai/" + id)])
      let refused = try await rig.evaluate("import {identity} from 'wuhu:space'; const i=await identity(); try {i.issuerFor('https://user:pass@lab.test')} catch(e) {result(e.name)}")
      #expect(refused == "TypeError")
    }
  }

  @Test func rosterIsTheServerDeclaration() async throws {
    try await withRig { rig in
      let rosters = try await rig.evaluate("import {toolRoster} from 'wuhu:session';result(await toolRoster())")
      let tools = rosters.object?["rosters"]?.array?.flatMap { $0.object?["tools"]?.array ?? [] } ?? []
      let script = try #require(tools.first { $0.object?["name"] == "run_script" })
      #expect(try #require(script.object?["description"]?.stringValue).count < 1500)
      #expect(try await rig.evaluate("import {toolRoster} from 'wuhu:session';result(await toolRoster())") == JSONValueEncoder().encode(sessionToolRosters()))
      let context = try await rig.evaluate("import {context} from 'wuhu:space';result(await context())")
      #expect(context.object?["contentHost"] == "https://shared.localhost")
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
