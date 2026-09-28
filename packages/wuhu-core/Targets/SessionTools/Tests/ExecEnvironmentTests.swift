import JSONValue
@testable import SessionTools
import Testing

private func resolve(_ arguments: JSONValue) throws -> ExecEnvironment {
  try execEnvironment(JSONValueDecoder().decode(ExecArguments.self, from: arguments))
}

@Suite struct ExecEnvironmentTests {
  @Test func absentMapsStayOffTheWire() throws {
    #expect(try resolve(.object(["machine": "box", "cwd": "/", "command": "true"])) == ExecEnvironment(env: nil, secrets: nil))
  }

  @Test func emptyMapsStayOffTheWire() throws {
    let resolved = try resolve(.object(["machine": "box", "cwd": "/", "command": "true", "env": .object([:]), "secrets": .object([:])]))
    #expect(resolved == ExecEnvironment(env: nil, secrets: nil))
  }

  @Test func bothMapsRideAlong() throws {
    let resolved = try resolve(.object([
      "machine": "box", "cwd": "/", "command": "true",
      "env": .object(["CI": "1", "_LANE": "beta"]),
      "secrets": .object(["TOKEN": "GITHUB_TOKEN"]),
    ]))
    #expect(resolved.env?.entries == ["CI": "1", "_LANE": "beta"])
    #expect(resolved.secrets?.entries == ["TOKEN": "GITHUB_TOKEN"])
  }

  @Test(arguments: ["1PASS", "a-b", "", "PATH ", "É", "A.B"])
  func unusableNamesAreRefused(_ name: String) throws {
    #expect(throws: ToolProblem.self) {
      try resolve(.object(["machine": "box", "cwd": "/", "command": "true", "env": .object([name: "x"])]))
    }
    #expect(throws: ToolProblem.self) {
      try resolve(.object(["machine": "box", "cwd": "/", "command": "true", "secrets": .object([name: "NAME"])]))
    }
  }

  @Test func aNameInBothMapsIsAnError() throws {
    do {
      _ = try resolve(.object([
        "machine": "box", "cwd": "/", "command": "true",
        "env": .object(["TOKEN": "hunter2"]),
        "secrets": .object(["TOKEN": "GITHUB_TOKEN"]),
      ]))
      Issue.record("a name set twice must be refused")
    } catch let problem as ToolProblem {
      #expect(problem.message.contains("TOKEN"))
      #expect(!problem.message.contains("hunter2"), "an error must never carry a value")
    }
  }
}
