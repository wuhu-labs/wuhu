import DeterministicDependencies
import class MainHub.Hub
import SessionDomain
@testable import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct MachineRosterTests {
  @Test func rosterCarriesIdAliasAndAttachState() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let mini = try await space.addMachineV2(name: "mac_mini").machine
      let builder = try await space.addMachineV2(name: "ci_box").machine
      let machineFS = FakeMachineFS()
      machineFS.attached.withLock { $0 = [mini.id] }
      var world = ToolWorld(
        executor: try await loop.executor(owner: loop.hub { Hub(space: space, machines: machineFS.seam) }),
        session: try await makeSession(space),
      )

      guard case let .machines(result) = try await world.run("machines", .object([:])) else {
        throw Mismatch("machines failed")
      }
      #expect(result.machines.map(\.id) == [mini.id, builder.id].map(\.rawValue).sorted())
      #expect(Set(result.machines.map(\.name)) == ["mac_mini", "ci_box"])
      #expect(result.machines.first { $0.id == mini.id.rawValue }?.attached == true)
      #expect(result.machines.first { $0.id == builder.id.rawValue }?.attached == false)

      let rendered = ToolResultPayload.machines(result).renderedText
      #expect(rendered.contains("mac_mini \(mini.id.rawValue) attached"))
      #expect(rendered.contains("ci_box \(builder.id.rawValue) detached"))
    }
  }

  @Test func anEmptySpaceSaysSoRatherThanReturningNothing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      var world = ToolWorld(
        executor: try await loop.executor(owner: loop.hub { Hub(space: space, machines: FakeMachineFS().seam) }),
        session: try await makeSession(space),
      )

      guard case let .machines(result) = try await world.run("machines", .object([:])) else {
        throw Mismatch("machines failed")
      }
      #expect(result.machines.isEmpty)
      #expect(ToolResultPayload.machines(result).renderedText == "no machines are enrolled in this space")
    }
  }

  @Test func aServerWithoutAMachineBackendRefuses() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      _ = try await space.addMachineV2(name: "mac_mini").machine
      var world = ToolWorld(executor: try await loop.executor(owner: loop.hub { Hub(space: space) }), session: try await makeSession(space))

      let message = try failureMessage(try await world.run("machines", .object([:])))
      #expect(message.contains("no machine backend"))
    }
  }
}
