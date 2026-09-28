import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct MachineRosterTests {
  @Test func rosterCarriesIdAliasAndAttachState() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let mini = try await space.addMachine(name: "mac-mini")
      let builder = try await space.addMachine(name: "ci-box")
      let machineFS = FakeMachineFS()
      machineFS.attached.withLock { $0 = [mini.id] }
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      guard case let .machines(result) = try await world.run("machines", .object([:])) else {
        throw Mismatch("machines failed")
      }
      #expect(result.machines.map(\.id) == [mini.id, builder.id].map(\.rawValue).sorted())
      #expect(Set(result.machines.map(\.name)) == ["mac-mini", "ci-box"])
      #expect(result.machines.first { $0.id == mini.id.rawValue }?.attached == true)
      #expect(result.machines.first { $0.id == builder.id.rawValue }?.attached == false)

      let rendered = ToolResultPayload.machines(result).renderedText
      #expect(rendered.contains("mac-mini \(mini.id.rawValue) attached"))
      #expect(rendered.contains("ci-box \(builder.id.rawValue) detached"))
    }
  }

  @Test func unnamedMachinesRenderAsIdAndStateOnly() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let anonymous = try await space.addMachine(name: nil)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam),
        session: try await makeSession(space),
      )

      guard case let .machines(result) = try await world.run("machines", .object([:])) else {
        throw Mismatch("machines failed")
      }
      #expect(result.machines.map(\.name) == [nil])
      #expect(ToolResultPayload.machines(result).renderedText == "\(anonymous.id.rawValue) detached")
    }
  }

  @Test func anEmptySpaceSaysSoRatherThanReturningNothing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam),
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
      _ = try await space.addMachine(name: "mac-mini")
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let message = try failureMessage(try await world.run("machines", .object([:])))
      #expect(message.contains("no machine backend"))
    }
  }
}
