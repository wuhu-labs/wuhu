import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import OperationProtocol
import Scratch
import Serve
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct MachineDeleteTests {
  @Test func deleteClosesTheBoxSocketAndRefusesItsOldKey() async throws {
    let f = try await MachineV2TunnelTests.Fixture()
    let opened = Gate(), closed = Gate()
    let box = try #require(f.space.worker.attach(BoxSocket.self, to: MachineCell.ID(f.machine.id.rawValue), opening: .init(connection: UUID(), pubkey: f.key.pubkeyLabel, streams: 32)) {
      switch $0 {
      case .frame: opened.open()
      case .closed: closed.open()
      }
    })
    defer { box.close() }
    await opened.wait()
    let result = try await f.handler(Request(url: URL(string: "https://space.test/v1/machine/scratch")!, method: .delete))
    guard case let .response(response) = result else { Issue.record("delete upgraded"); return }
    #expect(response.status == .ok)
    try await until("delete closes the owning box socket", timeout: .seconds(4)) { closed.isOpen }
    #expect(try await f.space.machine(f.machine.id) == nil)
    guard case let .response(refused) = try await f.connect(try await f.challenge(), machines: [f.machine.id.rawValue]) else { Issue.record("deleted key connected"); return }
    #expect(refused.status == .unauthorized)
    let fresh = try await f.space.addMachineV2(name: "scratch")
    #expect(fresh.machine.id != f.machine.id)
  }

  @Test func committedDeleteCleansCellStateAndSurvivesRestart() async throws {
    let folder = try ScratchFolder("machine-delete")
    let file = folder.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: file)
    let created = try await space.addMachineV2(name: "original")
    let machine = try await space.renameMachine(created.machine.id, name: "renamed")
    let key = Curve25519.Signing.PrivateKey()
    _ = try await space.consumeMachineV2JoinToken(created.token.token, pubkey: key.pubkeyLabel)
    let outstanding = try await space.mintJoinToken(account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 3600)
    let person = try await space.addAccount(kind: .human, name: nil)
    let deviceKey = Curve25519.Signing.PrivateKey()
    _ = try await space.addKey(deviceKey.pubkeyLabel, account: person.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey.pubkeyLabel, installation: "app", kind: "mac", name: "App")
    _ = try await space.annotateDevice(device.id, name: nil, machine: machine.id)
    let fs = await space.fs(.shared)
    _ = try await fs.write("/_/machines/renamed/AGENTS.md", Data("notes".utf8), ifMatch: nil)
    _ = try await fs.write("/_/machines/renamed/deep/child.md", Data("child".utf8), ifMatch: nil)
    let exec = try await space.reserveExec(machine: machine.id, caller: nil)
    let execRequest = try #require(try await space.execRequest(exec.id))
    let fileRequest = try await reserveFile(in: space, machine: machine.id, kind: "read.v1")
    let writeRequest = try await reserveFile(in: space, machine: machine.id, kind: "write.v1")
    let pointer = try #require(space.machineBuffers.put(Data("cached output".utf8), operation: fileRequest.operation, channel: "data", from: 0))
    let other = try await space.addMachineV2(name: "untouched", group: .settings)
    let otherKey = Curve25519.Signing.PrivateKey()
    _ = try await space.consumeMachineV2JoinToken(other.token.token, pubkey: otherKey.pubkeyLabel)
    let otherToken = try await space.mintJoinToken(account: other.machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 3600)
    let otherExec = try await space.reserveExec(machine: other.machine.id)
    let otherFile = try await reserveFile(in: space, machine: other.machine.id, kind: "read.v1")
    let otherPointer = try #require(space.machineBuffers.put(Data("untouched".utf8), operation: otherFile.operation, channel: "data", from: 0))
    _ = try await space.fs(.settings).write("/_/machines/untouched/AGENTS.md", Data("other notes".utf8), ifMatch: nil)
    let before = try await space.currentRevision()
    try await space.deleteMachine(machine.id, by: .shared(.anonymous))
    try await until("posted deletion cleans the owning cell and buffers", timeout: .seconds(4)) {
      space.worker.cell(MachineCell.ID(machine.id.rawValue)).presence.state == "deleted"
        && !space.worker.hasMail(for: MachineCell.ID(machine.id.rawValue).recipient)
        && space.machineBuffers.payload(pointer) == nil
    }
    #expect(space.machineBuffers.payload(pointer) == nil)
    #expect(space.machineBuffers.payload(otherPointer)?.data == Data("untouched".utf8))
    #expect(space.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(fileRequest.operation) == nil)
    #expect(space.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(writeRequest.operation) == nil)
    #expect(space.worker.cell(MachineCell.ID(other.machine.id.rawValue)).fileOperation(otherFile.operation)?.request == otherFile)
    #expect(try await space.currentRevision() == before + 1)
    try await space.close()

    let reopened = try Space.open(file: file)
    #expect(try await reopened.machine(machine.id) == nil)
    #expect(try await reopened.writer.read { db in
      try Substrate.descendantHeads(of: .init(validating: "/_/machines/\(machine.id.rawValue)"), group: .shared, in: db).isEmpty
    })
    #expect(try await reopened.account(machine.account) == nil)
    #expect(try await reopened.device(id: device.id)?.machine == nil)
    #expect(try await reopened.account(person.id) != nil)
    #expect(try await reopened.machine(pubkey: key.pubkeyLabel) == nil)
    #expect(try await reopened.machineV2Members(group: .shared).isEmpty)
    #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared) == nil)
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).presence.state == "deleted")
    #expect(try await reopened.execRecord(exec.id) == nil)
    #expect(try await reopened.execRequest(exec.id) == nil)
    await #expect(throws: JoinTokenRejected.self) { try await reopened.consumeJoinToken(outstanding.token, pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel) }
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(fileRequest.operation) == nil)
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(writeRequest.operation) == nil)
    #expect(try await reopened.machine(other.machine.id) == other.machine)
    #expect(try await reopened.machine(pubkey: otherKey.pubkeyLabel) == other.machine.id)
    #expect(try await reopened.machineV2Members(group: .settings) == [other.machine.id.rawValue])
    #expect(try await reopened.execRecord(otherExec.id) != nil)
    #expect(reopened.worker.cell(MachineCell.ID(other.machine.id.rawValue)).fileOperation(otherFile.operation)?.request == otherFile)
    #expect(try await reopened.fs(.settings).read("/_/machines/untouched/AGENTS.md").1 == Data("other notes".utf8))
    _ = try await reopened.consumeJoinToken(otherToken.token, pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel)
    await #expect(throws: OperationError(.unknownMachine, message: "Machine was deleted")) {
      try await reopened.worker.call(MachineCell.ID(machine.id.rawValue)) { try $0.reserve(execRequest) }
    }
    let original = try await reopened.addMachineV2(name: "original")
    let renamed = try await reopened.addMachineV2(name: "renamed")
    #expect(original.machine.id != machine.id && renamed.machine.id != machine.id)
    #expect(try await reopened.fs(.shared).list("/_/machines/renamed").1.isEmpty)
    try await reopened.close()
  }

  private func reserveFile(in space: Space, machine: MachineID, kind: String) async throws -> MachineFile {
    let request = MachineFile(operation: UUID(), start: .init(kind: kind, input: ["path": "/file"]))
    try await space.worker.call(MachineCell.ID(machine.rawValue)) {
      try $0.saveFile(MachineFileOperation(id: request.operation.uuidString.lowercased(), request: request, created: 1))
    }
    return request
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
      let exec = try await w.harness.space.reserveExec(machine: machine.id, caller: session.rawValue)
      let bearer = try await w.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
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
