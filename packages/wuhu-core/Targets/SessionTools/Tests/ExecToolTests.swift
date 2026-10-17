import Clocks
import Dependencies
import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import struct MachineContract.MachineID
import OrderedCollections
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

@Suite(.timeLimit(.minutes(2))) struct ExecToolTests {
  @Test func terminalCallerReconnectsAreBoundedEvenWhenLocalConnectSucceeds() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var backend = scripted.backend(space)
      let claim = try await backend.claim(machine, session, .init("terminal-drain"))
      try await space.finishExec(claim.record.id, .exited(code: 0))
      let connects = Box(0)
      backend.connect = { _ in
        connects.withLock { $0 += 1 }
        let (caller, peer) = InMemoryTransport.pair()
        peer.sever()
        return caller
      }
      let reason = try await withDependencies {
        $0.continuousClock = ImmediateClock()
      } operation: {
        try await holdExecLeg(claim.record.id, endpoint: ChannelEndpoint(), backend: backend)
      }
      #expect(reason?.contains("no longer replayable") == true)
      #expect(connects.value == 2)
    }
  }

  @Test func machineLostStopsAfterFirstSeverWithoutClaimingProcessExit() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      var backend = ScriptedExecMachine().backend(space)
      let claim = try await backend.claim(machine, session, .init("machine-lost"))
      try await space.finishExec(claim.record.id, .machineLost)
      let connects = Box(0)
      backend.connect = { _ in
        connects.withLock { $0 += 1 }
        let (caller, peer) = InMemoryTransport.pair()
        peer.sever()
        return caller
      }
      let reason = try await holdExecLeg(claim.record.id, endpoint: ChannelEndpoint(), backend: backend)
      #expect(reason?.contains("remote process outcome is unknown") == true)
      #expect(connects.value == 1)
    }
  }

  @Test func execRunsRecordsAReceiptAndAbsorbsTheRetry() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let acknowledged = Box(false)
      let scripted = ScriptedExecMachine(onTerminalAck: { ack in
        #expect(ack.cursor == 6)
        let receipt = try await space.sessions.receipt(session, toolCallID: .init("tc-exec"))
        #expect(receipt != nil)
        acknowledged.withLock { $0 = true }
      })
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
        #expect(acknowledged.value)
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

extension ExecToolTests {
  @Test(arguments: [nil, 30, 14400] as [Double?])
  func aKilledExecSaysWhichLifetimeEndedIt(_ explicit: Double?) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )
      let limit = explicit ?? 1800
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            #expect(exec.start.timeout == limit)
            try? await exec.send(.stdout, Array("working\n".utf8))
            await time.advance(by: limit)
            await exec.exit(.signaled(signal: 15), timedOut: .killed)
          }
        }
        var arguments: OrderedDictionary<String, JSONValue> = ["machine": .string(machine.rawValue), "cwd": "/work", "command": "sleep 7200", "wait_seconds": 20000]
        if let explicit { arguments["max_lifetime_seconds"] = .number(explicit) }
        guard case let .exec(result) = try await world.run("exec", ToolArguments(.object(arguments)), id: "tc-timeout") else {
          throw Mismatch("timed-out exec failed")
        }
        let note = explicit == nil
          ? "[killed after 1800 s, the default max lifetime; start longer work detached and watch it from run_script]"
          : "[killed after \(Int(limit)) s, its max_lifetime_seconds]"
        #expect(result.output == "working\n\n" + note)
        #expect(result.exitCode == 128 + 15)
        group.cancelAll()
      }
    }
  }

  @Test func anExecThatEndsInTimeCarriesNoLifetimeNote() async throws {
    try await withToolDeps { time in
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
            await time.advance(by: 1799)
            await exec.exit(.exited(code: 0))
          }
        }
        guard case let .exec(result) = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "make", "wait_seconds": 14400]), id: "tc-in-time",
        ) else { throw Mismatch("exec failed") }
        #expect(result.output == "")
        #expect(result.exitCode == 0)
        group.cancelAll()
      }
    }
  }

  /// The note comes from the machine's verdict, never from the clock: an
  /// exec that took longer than its lifetime to report but was not ended by
  /// it carries no note.
  @Test func aLateExitTheTimeoutDidNotCauseCarriesNoNote() async throws {
    try await withToolDeps { time in
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
            await time.advance(by: 1805)
            await exec.exit(.exited(code: 0))
          }
        }
        guard case let .exec(result) = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "make", "wait_seconds": 14400]), id: "tc-late",
        ) else { throw Mismatch("exec failed") }
        #expect(result.output == "")
        #expect(result.exitCode == 0)
        group.cancelAll()
      }
    }
  }

  @Test func aTimeoutWhoseExitStatusNeverCameBackIsARequestDeadline() async throws {
    try await withToolDeps { time in
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
            await time.advance(by: 60)
            await exec.exit(.exited(code: 1), timedOut: .statusUnknown)
          }
        }
        let outcome = try await world.run(
          "exec", .object(["machine": .string(machine.rawValue), "cwd": "/work", "command": "sleep 7200", "max_lifetime_seconds": .number(60)]),
          id: "tc-unknown",
        )
        guard case let .failure(failure) = outcome else {
          Issue.record("an unresolved timeout returned \(outcome)")
          group.cancelAll()
          return
        }
        #expect(failure.code == "requestDeadline")
        #expect(failure.message.contains("never came back"))
        group.cancelAll()
      }
    }
  }

  @Test func theOldNameOrAnOutOfRangeLifetimeNeverStartsAnExec() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.addMachine(name: "box")
      let scripted = ScriptedExecMachine()
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: FakeMachineFS().seam, exec: scripted.backend(space)),
        session: session,
      )
      let cases: [(String, JSONValue, String)] = [
        ("timeout_seconds", .number(30), "exec: timeout_seconds is renamed to max_lifetime_seconds"),
        ("max_lifetime_seconds", .number(14400.5), "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
        ("max_lifetime_seconds", .number(1e300), "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
        ("max_lifetime_seconds", .number(0), "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
      ]
      for (index, (name, value, message)) in cases.enumerated() {
        let refused = try await world.run(
          "exec", .object(["machine": "box", "cwd": "/work", "command": "true", name: value]), id: "tc-refused-\(index)",
        )
        guard case let .failure(failure) = refused else {
          Issue.record("\(name) \(value) was accepted")
          continue
        }
        #expect(failure.message == message)
        #expect(failure.code == "invalidArgument")
      }
      #expect(scripted.startCount.value == 0)
    }
  }
}
