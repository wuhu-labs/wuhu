import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import MachineContract
import OperationClient
import OperationProtocol
import Scratch
import Serve
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct MachineDeleteTests {
  @Test func deleteKicksTheTunnelAndRefusesItsOldKey() async throws {
    let f = try await MachineV2TunnelTests.Fixture()
    let aborted = Mutex(false)
    let credential = MachineV2Hub.Credential(pubkey: f.key.pubkeyLabel, machines: [f.machine.id.rawValue])
    _ = try await f.hub.attach(credential, client: .init { _ in Response(status: .ok) }, abort: { aborted.withLock { $0 = true } })
    let result = try await f.handler(Request(url: URL(string: "https://space.test/v1/machine/scratch")!, method: .delete))
    guard case let .response(response) = result else { Issue.record("delete upgraded"); return }
    #expect(response.status == .ok)
    #expect(aborted.withLock { $0 })
    #expect(try await f.space.machine(f.machine.id) == nil)
    guard case let .response(refused) = try await f.connect(try await f.challenge(), machines: [f.machine.id.rawValue]) else { Issue.record("deleted key connected"); return }
    #expect(refused.status == .unauthorized)
    let fresh = try await f.space.addMachineV2(name: "scratch")
    #expect(fresh.machine.id != f.machine.id)
  }

  @Test func committedDeleteSurvivesRestartBeforeTheKick() async throws {
    let folder = try ScratchFolder("machine-delete")
    let file = folder.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: file)
    let created = try await space.addMachineV2(name: "original")
    let machine = try await space.renameMachine(created.machine.id, name: "renamed")
    let key = Curve25519.Signing.PrivateKey()
    _ = try await space.consumeMachineV2JoinToken(created.token.token, pubkey: key.pubkeyLabel)
    let outstanding = try await space.mintJoinToken(account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 3600)
    try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .detached)
    let person = try await space.addAccount(kind: .human, name: nil)
    let deviceKey = Curve25519.Signing.PrivateKey()
    _ = try await space.addKey(deviceKey.pubkeyLabel, account: person.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey.pubkeyLabel, installation: "app", kind: "mac", name: "App")
    _ = try await space.annotateDevice(device.id, name: nil, machine: machine.id)
    let fs = await space.fs(.shared)
    _ = try await fs.write("/_/machines/renamed/AGENTS.md", Data("notes".utf8), ifMatch: nil)
    _ = try await fs.write("/_/machines/renamed/deep/child.md", Data("child".utf8), ifMatch: nil)
    let exec = try await space.mintExec(machine: machine.id, caller: nil)
    let encryption = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: encryption, problemsGroup: .shared)
    let owner = OperationOwner(scope: "exec/" + exec.id.rawValue, key: exec.id.rawValue)
    var record = ClientRecord(id: UUID(), correlation: UUID(), machine: machine.id.rawValue, start: .init(kind: "exec.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))
    _ = try await store.claim(owner, record: record)
    let chunk = OutputChunk(sequence: 0, channel: "stdout", from: .zero, payload: .init(data: Data("output".utf8)))
    record.output = [chunk]; record.committed["stdout"] = chunk.through; record.nextSequence = 1
    record.pendingInputs["stdin"] = .init(offset: .zero, payload: .init(data: Data("input".utf8)), end: false)
    try await store.save(record, appending: chunk)
    let otherStore = try await space.machineV2Store(group: .settings, key: encryption, problemsGroup: .shared)
    let otherRecord = ClientRecord(id: UUID(), correlation: UUID(), machine: machine.id.rawValue, start: record.start, description: record.description)
    _ = try await otherStore.claim(owner, record: otherRecord)
    let before = try await space.currentRevision()
    try await space.deleteMachine(machine.id, by: .shared(.anonymous))
    #expect(try await space.currentRevision() == before + 1)
    try await space.close()

    let reopened = try Space.open(file: file)
    #expect(try await reopened.machine(machine.id) == nil)
    #expect(try await reopened.account(machine.account) == nil)
    #expect(try await reopened.device(id: device.id)?.machine == nil)
    #expect(try await reopened.account(person.id) != nil)
    #expect(try await reopened.machine(pubkey: key.pubkeyLabel) == nil)
    #expect(try await reopened.machineV2Members(group: .shared).isEmpty)
    #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared) == nil)
    #expect(try await reopened.machineV2RecoveryGroups().isEmpty)
    #expect(try await reopened.execRecord(exec.id)?.terminal == .machineLost)
    await #expect(throws: JoinTokenRejected.self) { try await reopened.consumeJoinToken(outstanding.token, pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel) }
    let restored = try await reopened.machineV2Store(group: .shared, key: encryption, problemsGroup: .shared)
    #expect(try await restored.lookup(owner) == nil)
    let otherRestored = try await reopened.machineV2Store(group: .settings, key: encryption, problemsGroup: .shared)
    #expect(try await otherRestored.lookup(owner) == nil)
    await #expect(throws: OperationError.self) { try await restored.read(record.id) }
    await #expect(throws: OperationError.self) { try await restored.save(record, appending: nil) }
    await #expect(throws: OperationError.self) { try await restored.claim(owner, record: record) }
    let original = try await reopened.addMachineV2(name: "original")
    let renamed = try await reopened.addMachineV2(name: "renamed")
    #expect(original.machine.id != machine.id && renamed.machine.id != machine.id)
    #expect(try await reopened.fs(.shared).list("/_/machines/renamed").1.isEmpty)
    try await reopened.close()
  }

  @Test func onlyAHumanAdminMayDelete() async throws {
    try await withSessionDeps {
      let w = try await GroupAdminRoutesTests().world()
      let machine = try await w.harness.space.addMachineV2(name: "box", group: w.group).machine
      let grants = GroupAdminRoutesTests()
      #expect(try await grants.send(w, .put, "/v1/group/\(w.group.rawValue)/access", ["kind": "account", "id": .string(machine.account.rawValue), "role": "read"]).status == .ok)
      let key = try await w.harness.space.addKey(Curve25519.Signing.PrivateKey().pubkeyLabel, account: machine.account, capabilities: [.device], createdBy: nil, expiresAt: nil)
      _ = try await w.harness.space.adoptPersona(key: key)
      let device = try await w.harness.space.upsertDevice(pubkey: key.pubkey, installation: "machine-login", kind: "web", name: "Machine login")
      let child = try await w.harness.space.addAccount(kind: .human, name: nil)
      let childKey = try await w.harness.space.addKey(Curve25519.Signing.PrivateKey().pubkeyLabel, account: child.id, capabilities: [.device], createdBy: machine.account, expiresAt: nil)
      let childToken = try await w.harness.space.mintJoinToken(account: child.id, capabilities: [.device], createdBy: machine.account, lifetime: 3600)
      let endpoint = "/v1/machine/" + machine.id.rawValue
      let other = try await w.harness.enrolledBearer()
      func request(_ bearer: String) -> Request {
        var request = Request(url: URL(string: "https://space.test" + endpoint)!, method: .delete)
        request.headers[.authorization] = "Bearer " + bearer
        request.headers["wuhu-group"] = w.group.rawValue
        return request
      }
      #expect(try await w.harness.api(request(other.bearer)).status == .forbidden)
      let session = try await w.harness.store.createSession(group: w.group, title: "Admin", kind: .agent, createdBy: "person", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      let exec = try await w.harness.space.mintExec(machine: machine.id, caller: session.rawValue)
      let bearer = w.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
      #expect(try await w.harness.api(request(bearer)).status == .forbidden)
      #expect(try await w.harness.space.machine(machine.id) != nil)
      var fromShared = request(w.bearer)
      fromShared.headers["wuhu-group"] = GroupID.shared.rawValue
      #expect(try await w.harness.api(fromShared).status == .ok)
      #expect(try await w.harness.space.account(machine.account) == nil)
      #expect(try await w.harness.space.device(id: device.id) == nil)
      #expect(try await w.harness.space.personas().allSatisfy { $0.account != machine.account })
      #expect(try await grants.send(w, .get, "/v1/group/\(w.group.rawValue)").json(GroupDetail.self).entries.allSatisfy { $0.id != machine.account.rawValue })
      #expect(try await w.harness.space.credential(pubkey: childKey.pubkey) != nil)
      _ = try await w.harness.space.consumeJoinToken(childToken.token, pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel)
      #expect(try await w.harness.api(request(w.bearer)).status == .notFound)
    }
  }
}
