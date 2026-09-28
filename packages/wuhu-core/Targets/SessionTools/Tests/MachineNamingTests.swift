import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct MachineNamingTests {
  @Test func aPathResolvesAMachineNameAndKeepsTheIdInTheAddress() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let mini = try await space.addMachine(name: "mac-mini")
      let machineFS = FakeMachineFS()
      machineFS.put("/work/main.swift", "code", mtime: 100)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      guard case let .read(read) = try await world.run("read", .object(["path": "machines://MAC-MINI/work/main.swift"]))
      else { throw Mismatch("read by machine name failed") }
      #expect(read.path == "machines://\(mini.id.rawValue)/work/main.swift")
    }
  }

  @Test func aRenamedMachineAnswersToItsNewNameOnly() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let mini = try await space.addMachine(name: "mac-mini")
      let machineFS = FakeMachineFS()
      machineFS.put("/work/main.swift", "code", mtime: 100)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: try await makeSession(space),
      )

      _ = try await world.run("read", .object(["path": "machines://mac-mini/work/main.swift"]))
      _ = try await space.renameMachine(mini.id, name: "studio")

      guard case let .read(read) = try await world.run("read", .object(["path": "machines://studio/work/main.swift"]))
      else { throw Mismatch("read after rename failed") }
      #expect(read.path == "machines://\(mini.id.rawValue)/work/main.swift")

      let stale = try await world.run("read", .object(["path": "machines://mac-mini/work/main.swift"]))
      #expect(try failureMessage(stale) == "unknown machine: mac-mini")
    }
  }

  @Test func anUnknownMachineNameIsAToolFailureRatherThanAParseError() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam),
        session: try await makeSession(space),
      )

      let missing = try await world.run("read", .object(["path": "machines://ghost/work/a.txt"]))
      #expect(try failureMessage(missing) == "unknown machine: ghost")

      let unnamed = try await world.run("read", .object(["path": "machines:///x"]))
      #expect(try failureMessage(unnamed).contains("invalid machine id"))
    }
  }

  @Test func theRosterNamesTheBoxBeforeItsId() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let mini = try await space.addMachine(name: "mac-mini")
      let anonymous = try await space.addMachine(name: nil)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam),
        session: try await makeSession(space),
      )

      guard case let .machines(result) = try await world.run("machines", .object([:])) else {
        throw Mismatch("machines failed")
      }
      let rendered = ToolResultPayload.machines(result).renderedText
      #expect(rendered.contains("mac-mini \(mini.id.rawValue) detached"))
      #expect(rendered.contains("\n\(anonymous.id.rawValue) detached") || rendered.hasPrefix("\(anonymous.id.rawValue) detached"))
    }
  }
}
