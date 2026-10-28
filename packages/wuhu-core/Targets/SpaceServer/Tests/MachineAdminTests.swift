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
import struct SpaceContract.EnrollConsumeOutput
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MachineAdminTests {
  @Test func machineListAndStatusReportV2Presence() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, _) = try await addMachine(server)

    let before = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
    #expect(before == [MachineStatus(id: id, name: "box", group: "shared", attached: false, scope: "owner")])

    try await space.recordMachineV2Presence(id.rawValue, group: .shared, state: .attached, description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))
    let attached = MachineStatus(id: id, name: "box", group: "shared", attached: true, scope: "owner")
    #expect(try await server.http(.get, "/v1/machine").json([MachineStatus].self) == [attached])
    #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self) == attached)
    #expect(try await server.http(.get, "/v1/machine/\(id.rawValue)/status").json(MachineStatus.self) == attached)

    for state in [MachineV2Presence.detached, .lost] {
      try await space.recordMachineV2Presence(id.rawValue, group: .shared, state: state)
      let detached = MachineStatus(id: id, name: "box", group: "shared", attached: false, scope: "owner")
      #expect(try await server.http(.get, "/v1/machine").json([MachineStatus].self) == [detached])
      #expect(try await server.http(.get, "/v1/machine/box/status").json(MachineStatus.self) == detached)
    }
    #expect(try await server.http(.get, "/v1/machine/unknown/status").status == .notFound)
  }

  @Test func machineNamesNormalizeAndResolveAcrossRenames() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
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
    let server = TestServer(space: space, clock: ContinuousClock())
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
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)
    let walled = TestServer(space: space, clock: ContinuousClock(), dev: false)

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
