import DeterministicDependencies
import struct MachineContract.MachineID
@testable import Machines
import MachinesContract
import MachinesTesting
@testable import SpaceCore
import SpaceIDs
import Testing

@Suite(.deterministicDependencies)
struct MachineNameTests {
  @Test func addingStoresTheNameLowercasedAndRefusesACollision() async throws {
    let space = try makeSpace()
    let box = try await space.machineFamily.addMachineV2(name: "Mini").machine
    #expect(box.name == "mini")

    await #expect(throws: SpaceError.machineNameTakenByMachine("mini")) {
      try await space.machineFamily.addMachineV2(name: "MINI").machine
    }
    await #expect(throws: SpaceError.invalidMachineName("my box")) {
      try await space.machineFamily.addMachineV2(name: "my box").machine
    }
    #expect(try await space.machineFamily.machines().count == 1)
  }

  @Test func resolvingAcceptsEitherAnIDOrAName() async throws {
    let space = try makeSpace()
    let box = try await space.machineFamily.addMachineV2(name: "mini").machine
    #expect(try await space.machineFamily.resolveMachine(box.id.rawValue) == box)
    #expect(try await space.machineFamily.resolveMachine("MINI") == box)
    #expect(try await space.machineFamily.machine(named: "mini") == box)
    #expect(try await space.machineFamily.resolveMachine("mc_zzzzzzzz") == nil)
    #expect(try await space.machineFamily.resolveMachine("nothing") == nil)
  }

  @Test func renamingRedirectsTheOldNameAndRefusesAnOccupiedOne() async throws {
    let space = try makeSpace()
    let first = try await space.machineFamily.addMachineV2(name: "mini").machine
    let second = try await space.machineFamily.addMachineV2(name: "laptop").machine

    let renamed = try await space.machineFamily.renameMachine(first.id, name: "Studio")
    #expect(renamed.name == "studio")
    #expect(try await space.machineFamily.machine(named: "mini")?.id == first.id)
    #expect(try await space.machineFamily.resolveMachine("studio")?.id == first.id)

    await #expect(throws: SpaceError.machineNameTakenByMachine("laptop")) {
      try await space.machineFamily.renameMachine(first.id, name: "Laptop")
    }
    #expect(try await space.machineFamily.renameMachine(second.id, name: "laptop").name == "laptop")
    await #expect(throws: SpaceError.notFound("mc_zzzzzzzz")) {
      try await space.machineFamily.renameMachine(MachineID(rawValue: "mc_zzzzzzzz"), name: "ghost")
    }
  }

  @Test func aRevokedMachineKeepsEveryNameItEverHadUntilItIsDeleted() async throws {
    let space = try makeSpace()
    let member = try await space.addAccount(kind: .human, name: "Morgan")
    let foreign = try await space.createGroup(alias: "other", owner: member.id)
    let (old, token) = try await space.machineFamily.addMachineV2(name: "work-box")
    _ = try await space.machineFamily.enrollMachineV2(token: token.token, pubkey: testPubkey("old_box"))
    _ = try await space.machineFamily.renameMachine(old.id, name: "workstation")
    #expect(try await space.machineFamily.revokeMachine(old.id, presenting: testPubkey("old_box")))
    #expect(try await space.machineFamily.machine(named: "work-box")?.id == old.id)
    #expect(try await space.machineFamily.machine(named: "workstation")?.id == old.id)
    for name in ["work_box", "workstation"] {
      await #expect(throws: SpaceError.machineNameTakenByMachine(name)) { try await space.machineFamily.addMachineV2(name: name, group: foreign, scope: .reachable) }
      await #expect(throws: SpaceError.machineNameTakenByMachine(name)) { try await space.machineFamily.addMachineV2(name: name) }
      await #expect(throws: AliasError.taken(name)) { try await space.createGroup(alias: name, owner: member.id) }
    }
    #expect(try await space.machineFamily.machine(old.id)?.name == "workstation")
  }

  @Test func pendingEnrollmentKeepsBothCurrentAndRetiredNamesReserved() async throws {
    let space = try makeSpace()
    let machine = try await space.machineFamily.addMachineV2(name: "old-box").machine
    _ = try await space.machineFamily.renameMachine(machine.id, name: "desk")
    _ = try await space.machineFamily.rotateMachine(machine.id)
    for name in ["old_box", "desk"] {
      await #expect(throws: SpaceError.machineNameTakenByMachine(name)) { try await space.machineFamily.addMachineV2(name: name) }
      #expect(try await space.machineFamily.resolveMachine(name)?.id == machine.id)
    }
  }

  @Test func namesPermitUnderscores() {
    #expect(MachineName.normalized("mc_abcdefgh") == nil)
    #expect(MachineName.normalized("mini_box") == "mini_box")
    #expect(MachineName.normalized("Mini-Box") == "mini_box")
    #expect(MachineName.normalized("mc-abcdefgh") == nil)
    #expect(MachineName.normalized("Mini.local") == "mini.local")
    #expect(MachineName.normalized("-mini") == nil)
    #expect(MachineName.normalized("") == nil)
    #expect(MachineName.normalized(String(repeating: "a", count: 64)) == nil)
    #expect(MachineName.normalized("m") == "m")
  }
}
