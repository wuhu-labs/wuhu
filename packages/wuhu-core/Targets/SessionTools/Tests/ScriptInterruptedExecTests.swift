import DeterministicDependencies
import class MainHub.Hub
@testable import SessionTools
@testable import SpaceServer
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct ScriptInterruptedExecTests {
  @Test func interruptedExecKillsOnlyItsLiveClaimAndUsesRootMachineFacet() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "owner_box").id
      let scripted = ScriptedExecMachine()
      let claim = try await space.claimExec(machine: machine, caller: session.rawValue, toolCallID: .init("interrupted"))
      let files = FakeMachineFS().seam
      let owner = Hub(space: space, machines: files)
      let executor = scripted.executor(owner: owner)
      #expect(await executor.machineID("owner_box", as: session) == machine)
      await executor.killInterrupted(session: session, callID: .init("missing"))
      #expect(scripted.kills.value.isEmpty)
      await executor.killInterrupted(session: session, callID: .init("interrupted"))
      #expect(scripted.kills.value == [claim.record.id])
      await executor.killInterrupted(session: session, callID: .init("interrupted"))
      #expect(scripted.kills.value.count == 1)
    }
  }
}
