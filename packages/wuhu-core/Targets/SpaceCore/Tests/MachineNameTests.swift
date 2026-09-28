import struct MachineContract.MachineID
@testable import SpaceCore
import Testing

@Suite
struct MachineNameTests {
  @Test func addingStoresTheNameLowercasedAndRefusesACollision() async throws {
    let space = try makeSpace()
    let box = try await space.addMachine(name: "Mini")
    #expect(box.name == "mini")

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

  @Test func renamingFreesTheOldNameAndRefusesAnOccupiedOne() async throws {
    let space = try makeSpace()
    let first = try await space.addMachine(name: "mini")
    let second = try await space.addMachine(name: "laptop")

    let renamed = try await space.renameMachine(first.id, name: "Studio")
    #expect(renamed.name == "studio")
    #expect(try await space.machine(named: "mini") == nil)
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

    #expect(try await space.claimMachineName(first.id, preferred: "Mini").name == "mini")
    #expect(try await space.claimMachineName(second.id, preferred: "mini").name == "mini-2")
    #expect(try await space.claimMachineName(third.id, preferred: "mini").name == "mini-3")
    #expect(try await space.claimMachineName(second.id, preferred: "mini-2").name == "mini-2")
  }

  @Test func aNameCanNeverBeMistakenForAnID() {
    #expect(MachineName.normalized("mc_abcdefgh") == nil)
    #expect(MachineName.normalized("Mini.local") == "mini.local")
    #expect(MachineName.normalized("-mini") == nil)
    #expect(MachineName.normalized("") == nil)
    #expect(MachineName.normalized(String(repeating: "a", count: 64)) == nil)
    #expect(MachineName.normalized("m") == "m")
  }
}
