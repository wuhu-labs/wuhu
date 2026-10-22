import DeterministicDependencies
import struct MachineContract.MachineID
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct MachineNameTests {
  @Test func addingStoresTheNameLowercasedAndRefusesACollision() async throws {
    let space = try makeSpace()
    let box = try await space.addMachine(name: "Mini")
    #expect(box.name == "mini")
    _ = try await space.addKey(testPubkey("mini"), account: box.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)

    await #expect(throws: SpaceError.machineNameTaken("mini")) {
      try await space.addMachine(name: "MINI")
    }
    await #expect(throws: SpaceError.invalidMachineName("my box")) {
      try await space.addMachine(name: "my box")
    }
    #expect(try await space.machines().count == 1)
  }

  @Test func resolvingAcceptsEitherAnIDOrAName() async throws {
    let space = try makeSpace()
    let box = try await space.addMachine(name: "mini")
    #expect(try await space.resolveMachine(box.id.rawValue) == box)
    #expect(try await space.resolveMachine("MINI") == box)
    #expect(try await space.machine(named: "mini") == box)
    #expect(try await space.resolveMachine("mc_zzzzzzzz") == nil)
    #expect(try await space.resolveMachine("nothing") == nil)
  }

  @Test func renamingRedirectsTheOldNameAndRefusesAnOccupiedOne() async throws {
    let space = try makeSpace()
    let first = try await space.addMachine(name: "mini")
    let second = try await space.addMachine(name: "laptop")
    _ = try await space.addKey(testPubkey("laptop"), account: second.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)

    let renamed = try await space.renameMachine(first.id, name: "Studio")
    #expect(renamed.name == "studio")
    #expect(try await space.machine(named: "mini")?.id == first.id)
    #expect(try await space.resolveMachine("studio")?.id == first.id)

    await #expect(throws: SpaceError.machineNameTaken("laptop")) {
      try await space.renameMachine(first.id, name: "Laptop")
    }
    #expect(try await space.renameMachine(second.id, name: "laptop").name == "laptop")
    await #expect(throws: SpaceError.notFound("mc_zzzzzzzz")) {
      try await space.renameMachine(MachineID(rawValue: "mc_zzzzzzzz"), name: "ghost")
    }
  }

  @Test func joiningClaimsThePreferredNameAndSuffixesWhenTaken() async throws {
    let space = try makeSpace()
    let first = try await space.addMachine(name: nil)
    let second = try await space.addMachine(name: nil)
    let third = try await space.addMachine(name: nil)
    for machine in [first, second, third] {
      _ = try await space.addKey(testPubkey(machine.id.rawValue), account: machine.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    }

    #expect(try await space.claimMachineName(first.id, preferred: "Mini").name == "mini")
    #expect(try await space.claimMachineName(second.id, preferred: "mini").name == "mini_2")
    #expect(try await space.claimMachineName(third.id, preferred: "mini").name == "mini_3")
    #expect(try await space.claimMachineName(second.id, preferred: "mini_2").name == "mini_2")
  }

  @Test func revokedAliasesStayWithTheirOwnerGroupAndTransferTogetherToItsSuccessor() async throws {
    let space = try makeSpace()
    let member = try await space.addAccount(kind: .human, name: "Morgan")
    let foreign = try await space.createGroup(alias: "other", owner: member.id)
    let old = try await space.addMachine(name: "work-box")
    let key = try await space.addKey(testPubkey("old_box"), account: old.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    _ = try await space.renameMachine(old.id, name: "workstation")
    #expect(try await space.revokeMachine(old.id, presenting: key.pubkey))
    #expect(try await space.machine(named: "work-box")?.id == old.id)
    #expect(try await space.machine(named: "workstation")?.id == old.id)
    for name in ["work_box", "workstation"] {
      await #expect(throws: SpaceError.machineNameTaken(name)) { try await space.addMachineV2(name: name, group: foreign, scope: .reachable) }
      await #expect(throws: AliasError.taken(name)) { try await space.createGroup(alias: name, owner: member.id) }
    }
    let successor = try await space.addMachineV2(name: "work-box").machine
    #expect(successor.id != old.id)
    #expect(try await space.resolveMachine("work-box")?.id == successor.id)
    #expect(try await space.resolveMachine("workstation")?.id == successor.id)
    #expect(try await space.machine(old.id)?.name == nil)
    await #expect(throws: SpaceError.machineNameTaken("workstation")) { try await space.addMachine(name: "workstation", group: foreign) }
  }

  @Test func keylessLegacyNamesUseTheSameGroupScopedSuccessorRule() async throws {
    let space = try makeSpace()
    let member = try await space.addAccount(kind: .human, name: "Morgan")
    let foreign = try await space.createGroup(alias: "other", owner: member.id)
    let legacy = try await space.addMachine(name: "old-box")
    _ = try await space.renameMachine(legacy.id, name: "desk")
    await #expect(throws: SpaceError.machineNameTaken("old_box")) { try await space.addMachine(name: "old-box", group: foreign) }
    let successor = try await space.addMachineV2(name: "desk").machine
    #expect(try await space.resolveMachine("old-box")?.id == successor.id)
    #expect(try await space.resolveMachine("desk")?.id == successor.id)
  }

  @Test func pendingEnrollmentKeepsBothCurrentAndRetiredNamesReserved() async throws {
    let space = try makeSpace()
    let machine = try await space.addMachine(name: "old-box")
    _ = try await space.renameMachine(machine.id, name: "desk")
    _ = try await space.mintJoinToken(account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    for name in ["old_box", "desk"] {
      await #expect(throws: SpaceError.machineNameTaken(name)) { try await space.addMachineV2(name: name) }
      #expect(try await space.resolveMachine(name)?.id == machine.id)
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
