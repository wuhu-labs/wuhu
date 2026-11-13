import Crypto
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import struct MachineContract.MachineStatus
import struct OperationProtocol.MachineDescription
import struct SpaceContract.EnrollConsumeOutput
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MachineAdminTests {
  @Test func machineListAndStatusReportV2Presence() async throws {
    let space = try makeMachineSpace()
    let server = try await TestServer(space: space, clock: ContinuousClock())
    let (id, _) = try await addMachine(server)

    let before = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
    #expect(before == [MachineStatus(id: id, name: "box", group: "shared", attached: false, scope: "owner")])

    try await space.worker.call(MachineCell.ID(id.rawValue)) { cell in
      try cell.ensurePresence()
      var presence = cell.presence
      presence.state = "attached"
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      presence.leaseMs = description.limits.leaseMs
      presence.pollHoldMs = description.limits.pollHoldMs
      presence.pollBytes = description.limits.pollBytes
      presence.resultBytes = description.limits.resultBytes
      presence.execStdoutWindow = nil
      presence.execStderrWindow = nil
      try cell.save(MachineDescriptionRow(description: description))
      presence.observed = cell.now
      try cell.save(presence)
    }
    let attached = MachineStatus(id: id, name: "box", group: "shared", attached: true, scope: "owner")
    #expect(try await server.http(.get, "/v1/machine").json([MachineStatus].self) == [attached])
    #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self) == attached)
    #expect(try await server.http(.get, "/v1/machine/\(id.rawValue)/status").json(MachineStatus.self) == attached)

    do {
      try await space.worker.call(MachineCell.ID(id.rawValue)) { cell in
        var presence = cell.presence
        presence.state = "lost"
        try cell.save(presence)
      }
      let listed = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
      let seen = try #require(listed.first?.lastSeen)
      let detached = MachineStatus(id: id, name: "box", group: "shared", attached: false, scope: "owner", lastSeen: seen)
      #expect(listed == [detached])
      #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self) == detached)
    }
    #expect(try await server.http(.get, "/v1/machine/unknown/status").status == .notFound)
  }

  @Test func aMachineReportsTheDeviceLinkedToIt() async throws {
    let space = try makeMachineSpace()
    let server = try await TestServer(space: space, clock: ContinuousClock())
    let (id, _) = try await addMachine(server)
    #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self).device == nil)
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let pubkey = "ed25519:" + Data(repeating: 7, count: 32).base64EncodedString()
    _ = try await space.addKey(pubkey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: pubkey, installation: "install", kind: "mac", name: "Studio")
    _ = try await space.annotateDevice(device.id, name: nil, machine: id)
    #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self).device == device.id)
    #expect(try await server.http(.get, "/v1/machine").json([MachineStatus].self).map(\.device) == [device.id])
  }

  @Test func machineNamesNormalizeAndResolveAcrossRenames() async throws {
    let space = try makeMachineSpace()
    let server = try await TestServer(space: space, clock: ContinuousClock())
    let id = try await enroll(server, name: "Mini")
    #expect(try await space.machine(id)?.name == "mini")

    let renamed = try await server.http(.put, "/v1/machine/mini/name", json: .object(["name": .string("Studio")]))
    #expect(renamed.status == .ok)
    #expect(try await renamed.json(MachineStatus.self) == MachineStatus(id: id, name: "studio", group: "shared", attached: false, scope: "owner"))
    #expect(try await server.http(.get, "/v1/machine/mini/status").json(MachineStatus.self).id == id)
    #expect(try await server.http(.get, "/v1/machine/studio/status").json(MachineStatus.self).id == id)

    let junk = try await server.http(.put, "/v1/machine/studio/name", json: .object(["name": .string("my box")]))
    #expect(junk.status == .badRequest)
    let second = try await enroll(server, name: "laptop")
    let clash = try await server.http(.put, "/v1/machine/\(second.rawValue)/name", json: .object(["name": .string("STUDIO")]))
    #expect(clash.status == .conflict)
    #expect(try await space.machine(second)?.name == "laptop")

    let byID = try await server.http(.put, "/v1/machine/\(id.rawValue)/name", json: .object(["name": .string("Desktop")]))
    #expect(byID.status == .ok)
    #expect(try await byID.json(MachineStatus.self).name == "desktop")
    #expect(try await server.http(.put, "/v1/machine/unknown/name", json: .object(["name": .string("unused")])).status == .notFound)
  }

  @Test func adminRevokesAV2EnrolledMachineByNameOrID() async throws {
    let space = try makeMachineSpace()
    let server = try await TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == id)

    let revoked = try await server.http(.post, "/v1/machine/box/revoke")
    #expect(revoked.status == .ok)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
    #expect(try await space.machine(id) != nil)
    #expect(try await server.http(.post, "/v1/machine/\(id.rawValue)/revoke").status == .ok)
    #expect(try await server.http(.post, "/v1/machine/unknown/revoke").status == .notFound)
  }

  @Test func nonDevGateRejectsUnauthenticatedMachineAdministration() async throws {
    let space = try makeMachineSpace()
    let server = try await TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)
    let walled = try await TestServer(space: space, clock: ContinuousClock(), dev: false)

    #expect(try await walled.http(.get, "/v1/machine").status == .unauthorized)
    #expect(try await walled.http(.get, "/v1/machine/\(id.rawValue)/status").status == .unauthorized)
    #expect(try await walled.http(.put, "/v1/machine/box/name", json: .object(["name": .string("changed")])).status == .unauthorized)
    #expect(try await walled.http(.post, "/v1/machine/box/revoke").status == .unauthorized)
    #expect(try await walled.http(.post, "/v1/machine-v2", json: .object(["name": .string("another"), "pubkey": .string(Curve25519.Signing.PrivateKey().pubkeyLabel)])).status == .unauthorized)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == id)
    #expect(try await space.machine(id)?.name == "box")
  }

  private func enroll(_ server: TestServer, name: String) async throws -> MachineID {
    let key = Curve25519.Signing.PrivateKey()
    let response = try await server.http(.post, "/v1/machine-v2", json: .object([
      "name": .string(name), "pubkey": .string(key.pubkeyLabel),
    ]))
    #expect(response.status == .ok)
    let output = try await response.json(EnrollConsumeOutput.self)
    return MachineID(rawValue: try #require(output.machine))
  }
}
