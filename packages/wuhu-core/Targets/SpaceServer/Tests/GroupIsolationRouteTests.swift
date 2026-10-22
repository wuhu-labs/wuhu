import struct Credentials.SpaceSecretStores
import Crypto
import DeterministicDependencies
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
@testable import SpaceCore
@testable import SpaceServer
import Testing

// Group isolation over HTTP: secrets, machines, archive and the MCP
// seat live in groups. Alice and Bob are people with personal groups; Admin is
// a human admin of shared; P is a top-level agent in alice, S one in shared.
@Suite(.deterministicDependencies) struct GroupIsolationRouteTests {
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
    let adminGroup: GroupID
    let p: SessionID
    let s: SessionID
  }

  static let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))

  func world(_ body: (World) async throws -> Void) async throws {
    let folder = try scratchURL("group-isolation")
    defer { try? FileManager.default.removeItem(at: folder) }
    let stores = SpaceSecretStores(configDirectory: folder, spaceID: "spc_test")
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530", execTokens: tokens, secrets: stores, machineV2: true)
    let (alice, aliceKey) = try await harness.enrolledBearer()
    let aliceGroup = try await harness.space.ensurePersonalGroup(account: aliceKey.account)
    let (bob, bobKey) = try await harness.enrolledBearer()
    let bobGroup = try await harness.space.ensurePersonalGroup(account: bobKey.account)
    let (admin, adminKey) = try await harness.enrolledBearer()
    let adminGroup = try await harness.space.ensurePersonalGroup(account: adminKey.account)
    _ = try await harness.space.setAdmin(adminKey.account, admin: true)
    let p = try await harness.store.createSession(group: aliceGroup, title: "P", kind: .agent, createdBy: "owner", executor: Self.model)
    let s = try await harness.store.createSession(group: .shared, title: "S", kind: .agent, createdBy: "owner", executor: Self.model)
    try await body(World(
      harness: harness, tokens: tokens, stores: stores, folder: folder,
      alice: alice, aliceAccount: aliceKey.account, aliceGroup: aliceGroup, bob: bob, bobGroup: bobGroup, admin: admin, adminGroup: adminGroup, p: p, s: s,
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
        #expect(session.status == .ok)

        // `?group=` picks the store, and the admin check follows it: alice
        // administers her group, not shared.
        // shared's secrets are its own group's alone until its switch says
        // otherwise; the list may not be named from another group at all.
        let named = try await send(w, .put, "/v1/secret/Y?group=shared", value, bearer: w.alice, group: w.aliceGroup)
        #expect(named.status == .forbidden)
        #expect(try await code(named) == "unauthorized")
        let namedRemoval = try await send(w, .delete, "/v1/secret/Y?group=shared", bearer: w.alice, group: w.aliceGroup)
        #expect(namedRemoval.status == .forbidden)
        #expect(try await code(namedRemoval) == "unauthorized")

        // A value goes to the worker's token only; an exec's, which the
        // command can print, is refused.
        let fromExec = try await send(w, .get, "/v1/secret/Y", bearer: try await token(w, w.s))
        #expect(fromExec.status == .forbidden)
        #expect(try await code(fromExec) == "unauthorized")
        let fromWorker = try await send(w, .get, "/v1/secret/Y", bearer: w.tokens.sessionToken(w.s))
        #expect(fromWorker.status == .ok)
        #expect(try await fromWorker.body.json(JSONValue.self) == .object(["value": "v"]))
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
        let added = try await send(
          w, .post, "/v1/machine", .object(["name": "hers", "group": .string(w.aliceGroup.rawValue)]), bearer: w.alice,
        )
        #expect(added.status == .ok)
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)
        _ = try await w.harness.space.addMachine(name: "common")

        func listed(_ bearer: String, group: GroupID? = nil) async throws -> [String] {
          let response = try await send(w, .get, "/v1/machine", bearer: bearer, group: group)
          #expect(response.status == .ok)
          return try JSONValueDecoder().decode([MachineStatus].self, from: try await json(response)).compactMap(\.name).sorted()
        }
        #expect(try await listed(w.alice, group: w.aliceGroup) == ["hers"])
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

  @Test(arguments: ["/v1/machine", "/v1/machine-v2"])
  func anAdminAddsAMachineDirectlyToTheRequestedGroup(path: String) async throws {
    try await withSessionDeps {
      try await world { w in
        let added = try await send(w, .post, path, .object(["name": "common-v2", "group": "shared"]), bearer: w.admin)
        #expect(added.status == .ok)
        let output = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added))
        let id = output.id
        #expect(output.group == "shared")
        #expect(try await w.harness.space.machine(id)?.group == .shared)
        let listed = try await send(w, .get, "/v1/machine", bearer: try await token(w, w.s))
        #expect(listed.status == .ok)
        #expect(try JSONValueDecoder().decode([MachineStatus].self, from: try await json(listed)).contains { $0.id == id })
      }
    }
  }

  @Test(arguments: ["/v1/machine", "/v1/machine-v2"])
  func aSpaceAdminDoesNotNeedTheTargetGroupsMembership(path: String) async throws {
    try await withSessionDeps {
      try await world { w in
        let project = GroupID(rawValue: "project")
        try await w.harness.space.writer.write { db in
          try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('project', '2026-01-01T00:00:00Z')")
        }
        // A space admin administers every group but another person's own, so
        // it may act in one it holds no entry in.
        let actingAsTarget = try await send(
          w, .post, path, ["name": "admin-acting-v2", "group": .string(project.rawValue)], bearer: w.admin, group: project,
        )
        #expect(actingAsTarget.status == .ok)
        let body: JSONValue = ["name": "admin-only-v2", "group": .string(project.rawValue)]
        let added = try await send(w, .post, path, body, bearer: w.admin)
        #expect(added.status == .ok)
        let output = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added))
        #expect(output.group == project.rawValue)
        #expect(try await w.harness.space.machine(output.id)?.group == project)

        // Another person's own group is theirs: a space admin does not administer it.
        let personal: JSONValue = ["name": "not-hers", "group": .string(w.bobGroup.rawValue)]
        #expect(try await send(w, .post, path, personal, bearer: w.admin).status == .forbidden)
      }
    }
  }

  @Test(arguments: ["/v1/machine", "/v1/machine-v2"])
  func addingToAGroupRequiresItsAdminAndAnExistingGroup(path: String) async throws {
    try await withSessionDeps {
      try await world { w in
        let denied = try await send(w, .post, path, .object(["name": "denied-v2", "group": "shared"]), bearer: w.alice)
        #expect(denied.status == .forbidden)
        #expect(try await code(denied) == "adminRequired")
        let unknown = try await send(w, .post, path, .object(["name": "unknown-v2", "group": "missing"]), bearer: w.admin)
        #expect(unknown.status == .notFound)
        #expect(try await code(unknown) == "unknownGroup")
        #expect(try await w.harness.space.resolveMachine("denied-v2") == nil)
        #expect(try await w.harness.space.resolveMachine("unknown-v2") == nil)
      }
    }
  }

  @Test func aPersonEnrollsTheirAppMachineInOneCallLinkedToTheirOwnDevice() async throws {
    try await withSessionDeps {
      try await world { w in
        let (_, aliceDeviceKey) = try await w.harness.enrolledBearer(account: w.aliceAccount)
        let mac = try await w.harness.space.upsertDevice(pubkey: aliceDeviceKey.pubkey, installation: "alice-mac", kind: "mac", name: "Alice's Mac")
        let (_, strangerKey) = try await w.harness.enrolledBearer()
        let foreign = try await w.harness.space.upsertDevice(pubkey: strangerKey.pubkey, installation: "other-mac", kind: "mac", name: "Other Mac")
        func body(_ name: String, device: String, pubkey: String = Curve25519.Signing.PrivateKey().pubkeyLabel) -> JSONValue {
          ["name": .string(name), "pubkey": .string(pubkey), "device": .string(device), "group": .string(w.aliceGroup.rawValue)]
        }

        let refused = try await send(w, .post, "/v1/machine-v2", body("borrowed", device: foreign.id), bearer: w.alice)
        #expect(refused.status == .notFound)
        #expect(try await code(refused) == "unknownDevice")
        #expect(try await w.harness.space.device(id: foreign.id)?.machine == nil)
        let fromSession = try await send(w, .post, "/v1/machine-v2", body("agent-made", device: mac.id), bearer: try await token(w, w.p))
        #expect(fromSession.status == .forbidden)

        let pubkey = Curve25519.Signing.PrivateKey().pubkeyLabel
        let enrolled = try await send(w, .post, "/v1/machine-v2", body("alice-mac", device: mac.id, pubkey: pubkey), bearer: w.alice)
        #expect(enrolled.status == .ok)
        let output = try JSONValueDecoder().decode(EnrollConsumeOutput.self, from: try await json(enrolled))
        let machine = MachineID(rawValue: try #require(output.machine))
        #expect(try await w.harness.space.machine(machine)?.group == w.aliceGroup)
        #expect(try await w.harness.space.device(id: mac.id)?.machine == machine)
        #expect(try await w.harness.space.machineV2Members(group: w.aliceGroup).contains(machine.rawValue))

        // A retry after a lost response replays; another key under the name does not.
        let replayed = try await send(w, .post, "/v1/machine-v2", body("alice-mac", device: mac.id, pubkey: pubkey), bearer: w.alice)
        #expect(replayed.status == .ok)
        #expect(try JSONValueDecoder().decode(EnrollConsumeOutput.self, from: try await json(replayed)) == output)
        let otherKey = try await send(w, .post, "/v1/machine-v2", body("alice-mac", device: mac.id), bearer: w.alice)
        #expect(otherKey.status == .conflict)
        #expect(try await code(otherKey) == "machineNameTaken")
      }
    }
  }

  @Test func aBodylessMachineRegistrationTakesTheActingGroupAndItsAdmin() async throws {
    try await withSessionDeps {
      try await world { w in
        let refused = try await send(w, .post, "/v1/machine", bearer: w.alice)
        #expect(refused.status == .forbidden)
        #expect(try await code(refused) == "adminRequired")
        let added = try await send(w, .post, "/v1/machine", bearer: w.admin)
        #expect(added.status == .ok)
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        #expect(try await w.harness.space.machine(id)?.group == .shared)
      }
    }
  }

  @Test func aPersonsV2MachineTakesItsNamedGroupAndThatGroupsAdmin() async throws {
    try await withSessionDeps {
      try await world { w in
        let refused = try await send(w, .post, "/v1/machine-v2", .object(["name": "hers-v2"]), bearer: w.alice)
        #expect(refused.status == .forbidden)
        let added = try await send(
          w, .post, "/v1/machine-v2",
          .object(["name": "hers-v2", "group": .string(w.aliceGroup.rawValue)]), bearer: w.alice,
        )
        #expect(added.status == .ok)
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)
      }
    }
  }

  @Test func sessionRegistrationPolicyKeepsItsPrincipalGroup() async throws {
    try await withSessionDeps {
      try await world { w in
        let principal = Principal(actor: .session(w.p), group: w.aliceGroup)
        switch try await machineRegistrationGroup(nil, principal: principal, space: w.harness.space) {
        case let .success(group): #expect(group == w.aliceGroup)
        case .failure: Issue.record("a session's own group is where its machine lands")
        }
        switch try await machineRegistrationGroup("shared", principal: principal, space: w.harness.space) {
        case let .success(group): Issue.record("a session enrolls elsewhere only where its group administers; got \(group)")
        case let .failure(response): #expect(response.status == .forbidden)
        }
        switch try await machineRegistrationGroup("missing", principal: principal, space: w.harness.space) {
        case .success: Issue.record("an unknown group is no target")
        case let .failure(response): #expect(response.status == .notFound)
        }
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
        let common = try await w.harness.space.addMachine(name: "common", scope: .reachable)
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

  @Test func aSessionsV2ExecRefusesEveryOtherActorsDial() async throws {
    try await withSessionDeps {
      try await world { w in
        await w.harness.hub.configureV2(MachineV2Service(space: w.harness.space, hub: MachineV2Hub(space: w.harness.space), key: nil, failure: nil))
        let (machine, _) = try await w.harness.space.addMachineV2(name: "common-v2", group: .shared)
        let exec = try await w.harness.space.mintExec(machine: machine.id, caller: w.s.rawValue, group: .shared)
        #expect(try await dialRefusal(w, exec.id, bearer: w.bob) == .conflict)
        #expect(try await dialRefusal(w, exec.id, bearer: w.admin) == .conflict)
        #expect(try await dialRefusal(w, exec.id, bearer: try await token(w, w.s)) == nil)
        let own = try await w.harness.space.mintExec(machine: machine.id, group: .shared)
        #expect(try await dialRefusal(w, own.id, bearer: w.bob) == nil)
      }
    }
  }

  @Test func movingAMachineNeedsAnAdminOfBothGroups() async throws {
    try await withSessionDeps {
      try await world { w in
        let added = try await send(
          w, .post, "/v1/machine", .object(["name": "hers", "group": .string(w.aliceGroup.rawValue)]), bearer: w.alice,
        )
        let id = try JSONValueDecoder().decode(MachineAddOutput.self, from: try await json(added)).id
        let toShared: JSONValue = .object(["group": "shared"])
        let path = "/v1/machine/\(id.rawValue)/group"

        let notSharedAdmin = try await send(w, .put, path, toShared, bearer: w.alice)
        #expect(notSharedAdmin.status == .forbidden)
        #expect(try await code(notSharedAdmin) == "adminRequired")
        #expect(try await send(w, .put, path, .object(["group": "nowhere"]), bearer: w.alice).status == .notFound)
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)

        // Another person's own group is theirs: even a space admin does not move
        // its machine, and alice may once she administers the space herself.
        #expect(try await send(w, .put, path, toShared, bearer: w.admin).status == .notFound)
        #expect(try await w.harness.space.machine(id)?.group == w.aliceGroup)
        _ = try await w.harness.space.setAdmin(w.aliceAccount, admin: true)
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
        let descendant = try await w.harness.store.createSession(group: .shared, title: "someone else's child", kind: .task, parent: hers, createdBy: w.s.rawValue, executor: Self.model)
        #expect(try await send(w, .post, "/v1/session/\(descendant.rawValue)/archive", .object(["force": .bool(true)]), bearer: w.alice).status == .forbidden)
        #expect(try await send(w, .post, "/v1/session/\(hers.rawValue)/archive", bearer: w.alice).status == .ok)
        #expect(try await w.harness.store.record(descendant).lifecycle != .live)
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

  @Test func theRetiredMcpEndpointIsAbsent() async throws {
    try await withSessionDeps {
      try await world { w in
        for bearer in [w.alice, w.admin] {
          let response = try await send(w, .post, "/v1/session/\(w.p.rawValue)/mcp", .object([:]), bearer: bearer)
          #expect(response.status == .notFound)
        }
      }
    }
  }
}
