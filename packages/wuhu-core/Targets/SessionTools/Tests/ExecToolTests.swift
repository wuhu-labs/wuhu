import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import struct MachineContract.MachineID
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

@Suite(.timeLimit(.minutes(2))) struct ExecToolTests {
  @Test func execRunsRecordsAReceiptAndAbsorbsTheRetry() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("hello\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }

        guard case let .exec(result) = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "echo hello"]), id: "tc-exec",
        ) else { throw Mismatch("exec failed") }
        #expect(result.output == "hello\n")
        #expect(result.exitCode == 0)
        #expect(!result.reaped)

        let recorded = try await space.sessions.receipt(session, toolCallID: .init("tc-exec"))
        #expect(recorded == .exec(result))

        let retried = try await world.retry("exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "echo hello"]), id: "tc-exec")
        #expect(retried == .exec(result))
        #expect(scripted.startCount.value == 1, "the receipt-absorbed retry must not respawn")
        group.cancelAll()
      }
    }
  }

  @Test func crashRetryRejoinsTheSameExecWithoutRespawning() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      let executor = ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space))
      let world = ToolWorld(executor: executor, session: session)
      let gate = Gate()
      let sentFirstHalf = Box(false)

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("part1;".utf8))
            sentFirstHalf.withLock { $0 = true }
            await gate.wait()
            try? await exec.send(.stdout, Array("part2".utf8))
            await exec.exit(.exited(code: 0))
          }
        }

        let state = world.state
        let attempt = Task {
          try await executor.execute(
            session: session,
            call: .init(id: "tc-exec", name: "exec", arguments: .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "long run"])),
            state: state,
          )
        }
        while !sentFirstHalf.value { await Task.yield() }
        // Crash-shaped teardown: the kernel never saw a result, no receipt
        // exists, and the process keeps running.
        attempt.cancel()
        _ = try? await attempt.value
        #expect(try await space.sessions.receipt(session, toolCallID: .init("tc-exec")) == nil)

        gate.open()
        let retried = try await world.retry("exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "long run"]), id: "tc-exec")
        guard case let .exec(result) = retried else { throw Mismatch("rejoined exec failed: \(retried)") }
        #expect(result.output == "part1;part2", "the rejoin must replay the buffered stream from byte 0")
        #expect(result.exitCode == 0)
        #expect(scripted.startCount.value == 1, "a crash-retry rejoins; it never respawns")
        group.cancelAll()
      }
    }
  }

  @Test func reapedExecSurfacesTheHonestVerdict() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )

      // The prior attempt's exec was reaped past the rejoin deadline; the
      // machine holds the buffered output to termination.
      let claim = try await space.claimExec(
        machine: machine,
        caller: session.rawValue,
        toolCallID: .init("tc-exec"),
      )
      try await space.finishExec(claim.record.id, .reaped)

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("partial output".utf8))
            await exec.exit(.signaled(signal: 9))
          }
        }

        guard case let .exec(result) = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "long run"]), id: "tc-exec",
        ) else { throw Mismatch("reaped exec drain failed") }
        #expect(result.reaped, "the retry must see the reap verdict")
        #expect(result.output == "partial output")
        #expect(result.exitCode == 128 + 9)
        group.cancelAll()
      }
    }
  }

  @Test func envAndSecretsReachTheMachineAsGiven() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )
      let seen = Box<ExecStart?>(nil)

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            seen.withLock { $0 = exec.start }
            await exec.exit(.exited(code: 0))
          }
        }

        _ = try await world.run("exec", .object([
          "machine": .string(machine.rawValue), "cwd": "/work", "command": "printenv",
          "env": .object(["CI": "1"]),
          "secrets": .object(["TOKEN": "GITHUB_TOKEN"]),
        ]), id: "tc-exec")
        let start = try #require(seen.value)
        #expect(start.cwd == "/work")
        #expect(start.env?.entries == ["CI": "1"])
        #expect(start.secrets?.entries == ["TOKEN": "GITHUB_TOKEN"])
        group.cancelAll()
      }
    }
  }

  @Test func aVariableSetTwiceNeverStartsAnExec() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )

      let outcome = try await world.run("exec", .object([
        "machine": .string(machine.rawValue), "cwd": "/work", "command": "true",
        "env": .object(["TOKEN": "plain"]),
        "secrets": .object(["TOKEN": "GITHUB_TOKEN"]),
      ]), id: "tc-exec")
      guard case let .failure(failure) = outcome else { throw Mismatch("expected a refusal, got \(outcome)") }
      #expect(failure.message.contains("TOKEN"))
      #expect(!failure.message.contains("plain"))
      #expect(scripted.startCount.value == 0)
      #expect(try await space.sessions.receipt(session, toolCallID: .init("tc-exec")) == nil)
    }
  }

  @Test func hugeOutputIsTailClampedForTheTranscript() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )
      let chatty = (1 ... 6000).map { "line-\($0)" }.joined(separator: "\n")

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array(chatty.utf8))
            await exec.exit(.exited(code: 0))
          }
        }

        guard case let .exec(result) = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "very chatty"]), id: "tc-exec",
        ) else { throw Mismatch("exec failed") }
        #expect(result.exitCode == 0)
        #expect(result.output.contains("line-6000"))
        #expect(!result.output.contains("line-1\n"), "the head must be dropped, the tail kept")
        #expect(result.output.hasSuffix("[output was \(chatty.utf8.count) bytes; showing lines 4001-6000 of 6000]"))
        #expect(result.output.utf8.count < 60 << 10)
        group.cancelAll()
      }
    }
  }

  @Test func execInARepositoryCarriesItsInstructionsOnce() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.addMachine(name: "box")
      let machineFS = FakeMachineFS()
      machineFS.put("/work/.git/HEAD", "ref: refs/heads/main", mtime: 1)
      machineFS.put("/work/AGENTS.md", "repo manual", mtime: 1)
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam, exec: scripted.backend(space)),
        session: session,
      )

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask { await scripted.serve { exec in await exec.exit(.exited(code: 0)) } }

        let arguments: ToolArguments = .object(["machine": "box", "cwd": "/work", "command": "true"])
        guard case .exec = try await world.run("exec", arguments) else { throw Mismatch("exec failed") }
        #expect(try #require(world.delivered).text.contains("repo manual"))
        guard case .exec = try await world.run("exec", arguments) else { throw Mismatch("exec failed") }
        #expect(world.delivered == nil)
        group.cancelAll()
      }
    }
  }

  @Test func execRefusesARelativeWorkingDirectory() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.addMachine(name: "box")
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )

      let refused = try await world.run("exec", .object(["machine": "box", "cwd": "work", "command": "true"]))
      #expect(try failureMessage(refused).contains("absolute cwd"))
      #expect(scripted.startCount.value == 0)
    }
  }
}
