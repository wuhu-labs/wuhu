import struct Credentials.SpaceSecretStores
import Crypto
import Fetch
import Foundation
import JSONValue
import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Serve
import ServeTesting
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// Group isolation over HTTP: secrets, machines, the vault, archive and the MCP
// seat live in groups. Alice and Bob are people with personal groups; Admin is
// a human admin of shared; P is a top-level agent in alice, S one in shared.
@Suite struct GroupIsolationRouteTests {
  struct World {
    let harness: SessionHarness
    let tokens: ExecTokens
    let stores: SpaceSecretStores
    let folder: URL
    let alice: String
    let aliceAccount: AccountID
    let aliceGroup: GroupID
    let bob: String
    let bobGroup: GroupID
    let admin: String
    let p: SessionID
    let s: SessionID
  }

  static let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))

  func world(_ body: (World) async throws -> Void) async throws {
    let folder = try scratchURL("group-isolation")
    defer { try? FileManager.default.removeItem(at: folder) }
    let stores = SpaceSecretStores(configDirectory: folder, spaceID: "spc_test")
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530", execTokens: tokens, secrets: stores)
    let (alice, aliceKey) = try await harness.enrolledBearer()
    let aliceGroup = try await harness.space.ensurePersonalGroup(account: aliceKey.account)
    let (bob, bobKey) = try await harness.enrolledBearer()
    let bobGroup = try await harness.space.ensurePersonalGroup(account: bobKey.account)
    let (admin, adminKey) = try await harness.enrolledBearer()
    let adminGroup = try await harness.space.ensurePersonalGroup(account: adminKey.account)
    try await harness.space.addEdge(src: adminGroup, dst: .shared, kind: .admin, by: nil)
    let p = try await harness.store.createSession(group: aliceGroup, title: "P", kind: .agent, createdBy: "owner", executor: Self.model)
    let s = try await harness.store.createSession(group: .shared, title: "S", kind: .agent, createdBy: "owner", executor: Self.model)
    try await body(World(
      harness: harness, tokens: tokens, stores: stores, folder: folder,
      alice: alice, aliceAccount: aliceKey.account, aliceGroup: aliceGroup, bob: bob, bobGroup: bobGroup, admin: admin, p: p, s: s,
    ))
  }

  func send(
    _ w: World, _ method: Fetch.Method, _ path: String, _ body: JSONValue? = nil, bearer: String, group: GroupID? = nil,
  ) async throws -> Response {
    var request = Request(url: URL(string: "https://space.test\(path)")!, method: method)
    if let body {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    request.headers[.authorization] = "Bearer " + bearer
    if let group { request.headers[GroupHeader.name] = group.rawValue }
    return try await w.harness.api(request)
  }

  /// An exec token for `session`, minted on any machine.
  func token(_ w: World, _ session: SessionID) async throws -> String {
    let machine = try await w.harness.space.addMachine(name: nil)
    let exec = try await w.harness.space.mintExec(machine: machine.id, caller: session.rawValue)
    return w.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
  }

  func upgrade(_ path: String, headers extra: [(String, String)]) -> Request {
    var headers = RequestHeaders()
    headers.set("connection", "Upgrade")
    headers.set("upgrade", "websocket")
    headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    headers.set("sec-websocket-version", "13")
    for (name, value) in extra {
      headers.set(name, value)
    }
    return Request(url: URL(string: "https://space.test\(path)")!, headers: headers)
  }

  /// The status a caller-leg dial for `exec` is refused with; nil when admitted.
  func dialRefusal(_ w: World, _ exec: ExecID, bearer: String) async throws -> Status? {
    switch try await ServeTesting.upgrade(w.harness.handler, upgrade("/v1/exec/\(exec.rawValue)", headers: [("authorization", "Bearer " + bearer)])) {
    case let .response(response): response.status
    case .webSocket: nil
    }
  }

  /// Runs the hub and a real agent keyed and attached as `machine` while `body` runs.
  func attached(_ w: World, _ machine: MachineRecord, _ body: @escaping @Sendable () async throws -> Void) async throws {
    let key = Curve25519.Signing.PrivateKey()
    let label = "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString()
    _ = try await w.harness.space.addKey(label, account: machine.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    let challenge = try JSONValueDecoder().decode(
      MachineChallengeOutput.self, from: try await json(try await w.harness.get("/v1/machine/challenge")),
    ).challenge
    let signature = try key.signature(for: MachineConnect.signingPayload(challenge: challenge))
    let connect = upgrade("/v1/machine/connect", headers: [
      (MachineConnect.pubkeyHeader, label),
      (MachineConnect.challengeHeader, challenge),
      (MachineConnect.signatureHeader, signature.base64EncodedString()),
    ])
    guard case let .webSocket(socket, serve) = try await ServeTesting.upgrade(w.harness.handler, connect) else {
      Issue.record("the machine's connect was refused")
      return
    }
    let state = try ScratchFolder("m4-agent")
    defer { state.remove() }
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()
    dialer.offer(socket)
    let hub = w.harness.hub
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await hub.run() }
      group.addTask { await serve() }
      group.addTask { await agent.run(dial: dialer.dial) }
      group.addTask {
        #expect(try await realPollUntil { await hub.attachedMachines().contains(machine.id) })
        try await body()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  func code(_ response: Response) async throws -> String? {
    try await json(response).object?["code"]?.stringValue
  }

  func names(_ response: Response) async throws -> [String] {
    #expect(response.status == .ok)
    return try JSONValueDecoder().decode(SecretsOutput.self, from: try await json(response)).names
  }

  @Test func secretsLiveInTheActingGroupAndOnlyAdminsChangeThem() async throws {
    try await withSessionDeps {
      try await world { w in
        let value: JSONValue = .object(["value": "v"])
        let shared = try await send(w, .put, "/v1/secret/K", value, bearer: w.alice)
        #expect(shared.status == .forbidden)
        #expect(try await code(shared) == "adminRequired")

        #expect(try await send(w, .put, "/v1/secret/K", value, bearer: w.alice, group: w.aliceGroup).status == .ok)
        #expect(FileManager.default.fileExists(
          atPath: w.folder.appendingPathComponent("secrets/spc_test/\(w.aliceGroup.rawValue).json").path,
        ))
        #expect(try await w.stores.group(w.aliceGroup.rawValue).value(of: "K") == "v")
        #expect(try await names(try await send(w, .get, "/v1/secret", bearer: w.alice, group: w.aliceGroup)) == ["K"])
        #expect(try await names(try await send(w, .get, "/v1/secret", bearer: w.alice)) == [])

        #expect(try await send(w, .put, "/v1/secret/X", value, bearer: w.admin).status == .ok)
        #expect(try await w.stores.group("shared").value(of: "X") == "v")
        #expect(try await names(try await send(w, .get, "/v1/secret", bearer: w.alice)) == ["X"])
        let removal = try await send(w, .delete, "/v1/secret/X", bearer: w.alice)
        #expect(removal.status == .forbidden)
        #expect(try await code(removal) == "adminRequired")
        #expect(try await send(w, .delete, "/v1/secret/X", bearer: w.admin).status == .ok)
        #expect(try await send(w, .delete, "/v1/secret/K", bearer: w.alice, group: w.aliceGroup).status == .ok)

        let session = try await send(w, .put, "/v1/secret/Y", value, bearer: try await token(w, w.s))
        #expect(session.status == .forbidden)
      }
    }
  }

  @Test func aFlatSecretStoreRefusesToStartUntilItIsMovedIntoShared() async throws {
    try await withSessionDeps {
      let folder = try scratchURL("secrets-move")
      defer { try? FileManager.default.removeItem(at: folder) }
      let fresh = try secretStores(configDirectory: folder, spaceID: "spc_test")
      try await fresh.group("shared").set("GITHUB_TOKEN", to: "ghp_old")
      let spaces = folder.appendingPathComponent("secrets")
      let flat = spaces.appendingPathComponent("spc_test.json")
      let moved = spaces.appendingPathComponent("spc_test")
      try FileManager.default.moveItem(at: moved.appendingPathComponent("shared.json"), to: flat)
      try FileManager.default.removeItem(at: moved)

      #expect(throws: SecretsLayoutError.needsSecretsMove(flat)) {
        try secretStores(configDirectory: folder, spaceID: "spc_test")
      }
      let reason = SecretsLayoutError.needsSecretsMove(flat).description
      #expect(reason.hasPrefix("needsSecretsMove: "))
      #expect(reason.contains("mkdir -m 700 \(moved.path) && mv \(flat.path) \(moved.path)/shared.json"))

      // A plain mkdir leaves the folder 0755; opening the stores tightens it.
      try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
      try FileManager.default.moveItem(at: flat, to: moved.appendingPathComponent("shared.json"))
      let stores = try secretStores(configDirectory: folder, spaceID: "spc_test")
      #expect(try await stores.group("shared").value(of: "GITHUB_TOKEN") == "ghp_old")
      let mode = try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? Int
      #expect(mode == 0o700)
    }
  }

  @Test func aPersonsMachineJoinsTheirGroupAndOnlyItsReadersUseIt() async throws {
    try await withSessionDeps {
      try await world { w in
        let added = try await send(w, .post, "/v1/machine", .object(["name": "hers"]), bearer: w.alice)
        #expect(added.status == .ok)
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)
        _ = try await w.harness.space.addMachine(name: "common")

        func listed(_ bearer: String, group: GroupID? = nil) async throws -> [String] {
          let response = try await send(w, .get, "/v1/machine", bearer: bearer, group: group)
          #expect(response.status == .ok)
          return try JSONValueDecoder().decode([MachineStatus].self, from: try await json(response)).compactMap(\.name).sorted()
        }
        #expect(try await listed(w.alice, group: w.aliceGroup) == ["common", "hers"])
        #expect(try await listed(w.alice) == ["common"])
        #expect(try await listed(w.admin) == ["common"])

        let mint: JSONValue = .object(["machine": .string(id.rawValue)])
        let fromS = try await send(w, .post, "/v1/exec", mint, bearer: try await token(w, w.s))
        #expect(fromS.status == .notFound)
        #expect(try await send(w, .post, "/v1/exec", mint, bearer: try await token(w, w.p)).status == .ok)
        #expect(try await send(w, .post, "/v1/exec", mint, bearer: w.admin).status == .notFound)
        #expect(try await send(w, .post, "/v1/exec", mint, bearer: w.alice, group: w.aliceGroup).status == .ok)
      }
    }
  }

  // Every route that builds a tool context, a person's or a session's exec's,
  // reaches a machine only when the acting group reads the machine's group.
  @Test func machinePathsReachOnlyAMachineTheActingGroupMayUse() async throws {
    try await withSessionDeps {
      try await world { w in
        let hers = try await w.harness.space.addMachine(name: "hers", group: w.aliceGroup)
        let root = try scratchURL("group-machine")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rc = root.appendingPathComponent(".zshrc")
        try Data("mine".utf8).write(to: rc)
        let address = "machines://\(hers.id.rawValue)\(rc.path)"
        let read: JSONValue = .object(["path": .string(address)])
        let write: JSONValue = .object(["path": .string(address), "content": "pwned"])
        let s = try await token(w, w.s)
        let p = try await token(w, w.p)

        try await attached(w, hers) {
          for bearer in [w.bob, w.alice, w.admin, s] {
            for input in [read, write] {
              let tool = input == read ? "read" : "write"
              let refused = try await send(w, .post, "/v1/tools/\(tool)", input, bearer: bearer)
              #expect(refused.status == .unprocessableContent)
              #expect(try await code(refused) == "notFound")
            }
          }
          #expect(String(decoding: try Data(contentsOf: rc), as: UTF8.self) == "mine")

          #expect(try await send(w, .post, "/v1/tools/read", read, bearer: w.alice, group: w.aliceGroup).status == .ok)
          #expect(try await send(w, .post, "/v1/tools/read", read, bearer: p).status == .ok)
          let written = try await send(w, .post, "/v1/tools/write", .object(["path": .string(address), "content": "p's"]), bearer: p)
          #expect(written.status == .ok)
          #expect(String(decoding: try Data(contentsOf: rc), as: UTF8.self) == "p's")
        }
      }
    }
  }

  // An exec is homed in its session's group or the group a person minted it
  // from; only a group that reads that home lists, reads, kills or joins it.
  @Test func anExecIsSeenAndJoinedOnlyFromAGroupThatReadsItsHome() async throws {
    try await withSessionDeps {
      try await world { w in
        let common = try await w.harness.space.addMachine(name: "common")
        let mint: JSONValue = .object(["machine": .string(common.id.rawValue)])
        func minted(_ bearer: String, group: GroupID? = nil) async throws -> ExecID {
          let response = try await send(w, .post, "/v1/exec", mint, bearer: bearer, group: group)
          #expect(response.status == .ok)
          return try JSONValueDecoder().decode(ExecMintOutput.self, from: try await json(response)).id
        }
        let ofP = try await minted(try await token(w, w.p))
        let ofAlice = try await minted(w.alice, group: w.aliceGroup)
        let ofBob = try await minted(w.bob)
        #expect(try await w.harness.space.execRecord(ofP)?.group == w.aliceGroup)
        #expect(try await w.harness.space.execRecord(ofAlice)?.group == w.aliceGroup)
        #expect(try await w.harness.space.execRecord(ofBob)?.group == .shared)

        func listed(_ bearer: String, group: GroupID? = nil) async throws -> Set<ExecID> {
          let response = try await send(w, .get, "/v1/exec", bearer: bearer, group: group)
          #expect(response.status == .ok)
          let ids = try JSONValueDecoder().decode([ExecStatus].self, from: try await json(response)).map(\.id)
          return Set(ids).intersection([ofP, ofAlice, ofBob])
        }
        #expect(try await listed(w.bob) == [ofBob])
        #expect(try await listed(w.admin) == [ofBob])
        #expect(try await listed(w.alice, group: w.aliceGroup) == [ofP, ofAlice, ofBob])

        for exec in [ofP, ofAlice] {
          #expect(try await send(w, .get, "/v1/exec/\(exec.rawValue)", bearer: w.bob).status == .notFound)
          #expect(try await send(w, .post, "/v1/exec/\(exec.rawValue)/kill", bearer: w.bob).status == .notFound)
          #expect(try await dialRefusal(w, exec, bearer: w.bob) == .notFound)
          #expect(try await send(w, .get, "/v1/exec/\(exec.rawValue)", bearer: w.alice, group: w.aliceGroup).status == .ok)
          #expect(try await w.harness.space.execRecord(exec)?.terminal == nil)
        }
        #expect(try await send(w, .get, "/v1/exec/\(ofBob.rawValue)", bearer: w.bob).status == .ok)
      }
    }
  }

  @Test func movingAMachineNeedsAnAdminOfBothGroups() async throws {
    try await withSessionDeps {
      try await world { w in
        let added = try await send(w, .post, "/v1/machine", .object(["name": "hers"]), bearer: w.alice)
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        let toShared: JSONValue = .object(["group": "shared"])
        let path = "/v1/machine/\(id.rawValue)/group"

        let notSharedAdmin = try await send(w, .put, path, toShared, bearer: w.alice)
        #expect(notSharedAdmin.status == .forbidden)
        #expect(try await code(notSharedAdmin) == "adminRequired")
        #expect(try await send(w, .put, path, toShared, bearer: w.admin).status == .notFound)
        #expect(try await send(w, .put, path, .object(["group": "nowhere"]), bearer: w.alice).status == .notFound)
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)

        let aliceGroup = w.aliceGroup
        try await w.harness.space.addEdge(src: aliceGroup, dst: .shared, kind: .admin, by: nil)
        #expect(try await send(w, .put, path, toShared, bearer: w.alice).status == .ok)
        #expect(try await w.harness.space.machine(id)?.group == .shared)
        let fromS = try await send(w, .post, "/v1/exec", .object(["machine": .string(id.rawValue)]), bearer: try await token(w, w.s))
        #expect(fromS.status == .ok)
      }
    }
  }

  @Test func renamingAMachineNeedsAnAdminOfItsGroup() async throws {
    try await withSessionDeps {
      try await world { w in
        let common = try await w.harness.space.addMachine(name: "common")
        let path = "/v1/machine/\(common.id.rawValue)/name"

        let refused = try await send(w, .put, path, .object(["name": "alices-now"]), bearer: w.alice)
        #expect(refused.status == .forbidden)
        #expect(try await code(refused) == "adminRequired")
        #expect(try await w.harness.space.machine(common.id)?.name == "common")
        #expect(try await send(w, .put, path, .object(["name": "studio"]), bearer: w.admin).status == .ok)
        #expect(try await w.harness.space.machine(common.id)?.name == "studio")

        let hers = try await w.harness.space.addMachine(name: "hers", group: w.aliceGroup)
        let own = try await send(w, .put, "/v1/machine/\(hers.id.rawValue)/name", .object(["name": "her-box"]), bearer: w.alice, group: w.aliceGroup)
        #expect(own.status == .ok)
        #expect(try await w.harness.space.machine(hers.id)?.name == "her-box")
      }
    }
  }

  @Test func theVaultSetsForAdminsAndRemovesForHumanAdmins() async throws {
    try await withSessionDeps {
      try await world { w in
        let common = try await w.harness.space.addMachine(name: "common")
        let path = "/v1/machine/\(common.id.rawValue)/vault"
        let entry: JSONValue = .object(["name": "K", "value": "v"])

        let set = try await send(w, .post, path, entry, bearer: w.alice)
        #expect(set.status == .forbidden)
        #expect(try await code(set) == "adminRequired")
        let removal = try await send(w, .delete, path + "/K", bearer: w.alice)
        #expect(removal.status == .forbidden)
        #expect(try await code(removal) == "adminRequired")
        // Past the gates, the machine isn't attached.
        #expect(try await send(w, .get, path, bearer: w.alice).status == .serviceUnavailable)
        #expect(try await send(w, .post, path, entry, bearer: w.admin).status == .serviceUnavailable)
        #expect(try await send(w, .delete, path + "/K", bearer: w.admin).status == .serviceUnavailable)
        let hers = try await w.harness.space.addMachine(name: "hers", group: w.aliceGroup)
        #expect(try await send(w, .get, "/v1/machine/\(hers.id.rawValue)/vault", bearer: w.bob, group: w.bobGroup).status == .notFound)
        #expect(try await send(w, .get, "/v1/machine/\(hers.id.rawValue)/vault", bearer: w.bob).status == .notFound)
      }
    }
  }

  @Test func archiveIsForTheCreatorAndHumanAdminsOfTheSessionsGroup() async throws {
    try await withSessionDeps {
      try await world { w in
        #expect(try await send(w, .post, "/v1/session/\(w.p.rawValue)/archive", bearer: w.bob).status == .notFound)
        #expect(try await w.harness.store.record(w.p).lifecycle == .live)
        let aliceAct = try await send(w, .post, "/v1/session/\(w.p.rawValue)/archive", bearer: w.alice, group: w.aliceGroup)
        #expect(aliceAct.status == .ok)
        #expect(try await w.harness.store.record(w.p).lifecycle != .live)

        let refused = try await send(w, .post, "/v1/session/\(w.s.rawValue)/archive", bearer: w.alice)
        #expect(refused.status == .forbidden)
        #expect(try await w.harness.store.record(w.s).lifecycle == .live)

        let persona = try #require(try await w.harness.space.persona(account: w.aliceAccount)).name
        let hers = try await w.harness.store.createSession(group: .shared, title: "hers", kind: .agent, createdBy: persona, executor: Self.model)
        #expect(try await send(w, .post, "/v1/session/\(hers.rawValue)/archive", bearer: w.alice).status == .ok)
        #expect(try await send(w, .post, "/v1/session/\(w.s.rawValue)/archive", bearer: w.admin).status == .ok)
      }
    }
  }

  @Test func aSessionDeletesNoAccount() async throws {
    try await withSessionDeps {
      try await world { w in
        let refused = try await send(w, .delete, "/v1/accounts/\(w.aliceAccount.rawValue)", bearer: try await token(w, w.s))
        #expect(refused.status == .forbidden)
        #expect(try await refused.text().contains(sessionRefusalMessage))
      }
    }
  }

  @Test func actingAsASessionOverMcpNeedsAHumanAdminOfItsGroup() async throws {
    try await withSessionDeps {
      try await world { w in
        let list = rpc("tools/list")
        #expect(try await send(w, .post, "/v1/session/\(w.p.rawValue)/mcp", list, bearer: w.alice).status == .ok)
        let admin = try await send(w, .post, "/v1/session/\(w.p.rawValue)/mcp", list, bearer: w.admin)
        #expect(admin.status == .forbidden)
        let alice = try await send(w, .post, "/v1/session/\(w.s.rawValue)/mcp", list, bearer: w.alice)
        #expect(alice.status == .forbidden)
        #expect(try await send(w, .post, "/v1/session/\(w.s.rawValue)/mcp", list, bearer: w.admin).status == .ok)
      }
    }
  }
}
