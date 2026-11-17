import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
@testable import Machines
import MachinesContract
import struct SpaceIDs.GroupID
import TenancyContract
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import MachineContract
import MachinesTesting
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
    let box = try #require(await f.space.worker.attach(BoxSocket.self, to: MachineCell.ID(f.machine.id.rawValue), opening: .init(connection: UUID(), pubkey: f.key.pubkeyLabel, streams: 32)) {
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
    #expect(try await f.space.machineFamily.machine(f.machine.id) == nil)
    guard case let .response(refused) = try await f.connect(try await f.challenge(), machines: [f.machine.id.rawValue]) else { Issue.record("deleted key connected"); return }
    #expect(refused.status == .unauthorized)
    try await until("the deleted machine's name is free again", timeout: .seconds(4)) {
      try await f.space.machineFamily.machine(named: "scratch") == nil
    }
    let fresh = try await f.space.machineFamily.addMachineV2(name: "scratch")
    #expect(fresh.machine.id != f.machine.id)
  }

  @Test func committedDeleteCleansCellStateAndSurvivesRestart() async throws {
    let folder = try ScratchFolder("machine-delete")
    let file = folder.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: file).registeringMachines()
    let created = try await space.machineFamily.addMachineV2(name: "original")
    let machine = try await space.machineFamily.renameMachine(created.machine.id, name: "renamed")
    let key = Curve25519.Signing.PrivateKey()
    _ = try await space.machineFamily.enrollMachineV2(token: created.token.token, pubkey: key.pubkeyLabel)
    let person = try await space.addAccount(kind: .human, name: nil)
    let deviceKey = Curve25519.Signing.PrivateKey()
    _ = try await space.addKey(deviceKey.pubkeyLabel, account: person.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey.pubkeyLabel, installation: "app", kind: "mac", name: "App")
    _ = try await space.annotateDevice(device.id, name: nil, machine: machine.id)
    let fs = await space.fs(.shared)
    _ = try await fs.write("/_/machines/renamed/AGENTS.md", Data("notes".utf8), ifMatch: nil)
    _ = try await fs.write("/_/machines/renamed/deep/child.md", Data("child".utf8), ifMatch: nil)
    let exec = try await space.machineFamily.reserveExec(machine: machine.id, caller: nil)
    let execRequest = try #require(try await space.machineFamily.execRequest(exec.id))
    let fileRequest = try await reserveFile(in: space, machine: machine.id, kind: "read.v1")
    let writeRequest = try await reserveFile(in: space, machine: machine.id, kind: "write.v1")
    let pointer = try #require(space.machineFamily.buffers.put(Data("cached output".utf8), operation: fileRequest.operation, channel: "data", from: 0))
    let other = try await space.machineFamily.addMachineV2(name: "untouched", group: .settings)
    let otherKey = Curve25519.Signing.PrivateKey()
    _ = try await space.machineFamily.enrollMachineV2(token: other.token.token, pubkey: otherKey.pubkeyLabel)
    let otherExec = try await space.machineFamily.reserveExec(machine: other.machine.id)
    let otherFile = try await reserveFile(in: space, machine: other.machine.id, kind: "read.v1")
    let otherPointer = try #require(space.machineFamily.buffers.put(Data("untouched".utf8), operation: otherFile.operation, channel: "data", from: 0))
    _ = try await space.fs(.settings).write("/_/machines/untouched/AGENTS.md", Data("other notes".utf8), ifMatch: nil)
    let before = try await space.currentRevision(in: .shared)
    try await space.machineFamily.deleteMachine(machine.id, by: machineCaller(Principal(actor: try await space.ensureDevPerson().actor, group: .shared), space: space))
    try await until("posted deletion cleans the owning cell and buffers", timeout: .seconds(4)) {
      space.worker.cell(MachineCell.ID(machine.id.rawValue)).presence.state == "deleted"
        && !space.worker.hasMail(for: MachineCell.ID(machine.id.rawValue).recipient)
        && !space.worker.hasMail(for: FilesCell.ID(GroupID.shared.rawValue).recipient)
        && space.machineFamily.buffers.payload(pointer) == nil
    }
    #expect(space.machineFamily.buffers.payload(pointer) == nil)
    #expect(space.machineFamily.buffers.payload(otherPointer)?.data == Data("untouched".utf8))
    #expect(space.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(fileRequest.operation) == nil)
    #expect(space.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(writeRequest.operation) == nil)
    #expect(space.worker.cell(MachineCell.ID(other.machine.id.rawValue)).fileOperation(otherFile.operation)?.request == otherFile)
    #expect(try await space.currentRevision(in: .shared) == before + 1)
    try await space.close()

    let reopened = try Space.open(file: file).registeringMachines()
    #expect(try await reopened.machineFamily.machine(machine.id) == nil)
    #expect(reopened.worker.cell(FilesCell.ID(GroupID.shared.rawValue)).subtree(try .init(validating: "/_/machines/\(machine.id.rawValue)")).isEmpty)
    #expect(try await reopened.device(id: device.id)?.machine == nil)
    #expect(try await reopened.account(person.id) != nil)
    #expect(try await reopened.machineFamily.machine(pubkey: key.pubkeyLabel) == nil)
    #expect(try await reopened.machineFamily.machineV2Members(group: .shared).isEmpty)
    #expect(try await reopened.machineFamily.machineV2PresenceEvidence(machine.id.rawValue, group: .shared) == nil)
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).presence.state == "deleted")
    #expect(try await reopened.machineFamily.execRecord(exec.id) == nil)
    #expect(try await reopened.machineFamily.execRequest(exec.id) == nil)
    await #expect(throws: JoinTokenRejected.self) { try await reopened.machineFamily.enrollMachineV2(token: created.token.token, pubkey: key.pubkeyLabel) }
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(fileRequest.operation) == nil)
    #expect(reopened.worker.cell(MachineCell.ID(machine.id.rawValue)).fileOperation(writeRequest.operation) == nil)
    #expect(try await reopened.machineFamily.machine(other.machine.id) == other.machine)
    #expect(try await reopened.machineFamily.machine(pubkey: otherKey.pubkeyLabel) == other.machine.id)
    #expect(try await reopened.machineFamily.machineV2Members(group: .settings) == [other.machine.id.rawValue])
    #expect(try await reopened.machineFamily.execRecord(otherExec.id) != nil)
    #expect(reopened.worker.cell(MachineCell.ID(other.machine.id.rawValue)).fileOperation(otherFile.operation)?.request == otherFile)
    #expect(try await reopened.fs(.settings).read("/_/machines/untouched/AGENTS.md").1 == Data("other notes".utf8))
    #expect(try await reopened.machineFamily.enrollMachineV2(token: other.token.token, pubkey: otherKey.pubkeyLabel) == other.machine)
    await #expect(throws: OperationError(.unknownMachine, message: "Machine was deleted")) {
      try await reopened.worker.call(MachineCell.ID(machine.id.rawValue)) { try $0.reserve(execRequest) }
    }
    let original = try await reopened.machineFamily.addMachineV2(name: "original")
    let renamed = try await reopened.machineFamily.addMachineV2(name: "renamed")
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
}
