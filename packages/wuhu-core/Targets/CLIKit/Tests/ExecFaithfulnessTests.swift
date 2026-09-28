import CLIKit
import Foundation
import Testing

@Suite struct ExecFaithfulnessTests {
  @Test func execStdoutIsPipeCleanAndByteExact() async throws {
    try await execScenario { h, m in
      let io = CLIIO()
      let code = await h.run(
        ["exec", "--cwd", "machines://\(m.id)\(h.box.path)", "--", "sh", "-c", "printf 'a\\377b'; printf 'oops' >&2; pwd"],
        io: io,
      )
      #expect(code == 0)
      let stdout = await io.stdoutBytes()
      #expect(Array(stdout.prefix(3)) == [0x61, 0xFF, 0x62])
      #expect(String(decoding: stdout.dropFirst(3), as: UTF8.self).hasSuffix("/box\n"))
      #expect(await io.stderrText() == "oops")
    }
  }

  @Test func execAddressesAMachineByName() async throws {
    try await execScenario { h, _ in
      let io = CLIIO()
      #expect(await h.run(["exec", "--cwd", "machines://BOX\(h.box.path)", "--", "pwd"], io: io) == 0)
      #expect(await io.stdoutText().hasSuffix("/box\n"))

      let missing = CLIIO()
      #expect(await h.run(["exec", "--cwd", "machines://ghost/", "--", "pwd"], io: missing) == 1)
      #expect(await missing.stderrText().contains("no machine named ghost"))
    }
  }

  @Test func execPipesStdinAndHalfClosesOnEOF() async throws {
    try await execScenario { h, m in
      let io = CLIIO(interactive: true)
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask { await h.run(["exec", "--cwd", "machines://\(m.id)/", "--", "cat"], io: io) }
        io.sendStdin("first|")
        #expect(try await pollUntil { await io.stdoutText() == "first|" })
        io.sendStdin("second")
        io.closeStdin()
        let code = try await group.next()
        #expect(code == 0)
        #expect(await io.stdoutText() == "first|second")
      }
    }
  }

  @Test func execTerminalStdinGetsImmediateEOF() async throws {
    try await execScenario { h, m in
      let io = CLIIO(terminal: true)
      let code = await h.run(["exec", "--cwd", "machines://\(m.id)/", "--", "cat"], io: io)
      #expect(code == 0)
      #expect(await io.stdoutBytes().isEmpty)
    }
  }

  @Test func execPassesExitCodesAndSignalsThrough() async throws {
    try await execScenario { h, m in
      let cwd = "machines://\(m.id)/"
      #expect(await h.run(["exec", "--cwd", cwd, "--", "sh", "-c", "exit 7"]) == 7)
      #expect(await h.run(["exec", "--cwd", cwd, "--", "sh", "-c", "kill -TERM $$"]) == 143)
      #expect(await h.run(["exec", "--cwd", cwd, "--", "definitely-not-a-real-binary"]) == 127)
    }
  }

  @Test func execInjectsAndMasksVaultSecrets() async throws {
    try await execScenario { h, m in
      let setIO = CLIIO(stdin: "hunter2-secret-value\n")
      #expect(await h.run(["vault", "set", m.id, "API_KEY"], io: setIO) == 0)

      let io = CLIIO()
      let code = await h.run(
        ["exec", "--cwd", "machines://\(m.id)/", "--secret", "TOKEN=API_KEY", "--", "sh", "-c", "echo token=$TOKEN"],
        io: io,
      )
      #expect(code == 0)
      #expect(await io.stdoutText() == "token=***\n")

      let unknown = CLIIO()
      let failed = await h.run(
        ["exec", "--cwd", "machines://\(m.id)/", "--secret", "X=NO_SUCH_SECRET", "--", "sh", "-c", "true"],
        io: unknown,
      )
      #expect(failed == 127)
      #expect(await unknown.stderrText().contains("wuhu:"))
    }
  }

  @Test func execMaxOutputTruncatesLoudlyAndKills() async throws {
    try await execScenario { h, m in
      let io = CLIIO()
      let code = await h.run(
        ["exec", "--cwd", "machines://\(m.id)/", "--max-output", "2048", "--", "yes", "0123456789"],
        io: io,
      )
      #expect(code >= 129)
      #expect(await io.stdoutBytes().count == 2048)
      #expect(await io.stderrText().contains("truncated at 2048"))
    }
  }

  @Test func execTimeoutKillsAsSignaled() async throws {
    try await execScenario { h, m in
      let code = await h.run(["exec", "--cwd", "machines://\(m.id)/", "--timeout", "0.3", "--", "sleep", "30"])
      #expect(code == 143)
    }
  }

  @Test func execCallerBlipResumesByteExactWithoutDoubleSpawn() async throws {
    try await execScenario { h, m in
      let marker = h.box.appendingPathComponent("spawns.txt").path
      let io = CLIIO(interactive: true)
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          await h.run(
            ["exec", "--cwd", "machines://\(m.id)/", "--", "sh", "-c", "echo spawn >> \(marker); cat"],
            io: io,
          )
        }
        io.sendStdin("first|")
        #expect(try await pollUntil { await io.stdoutText() == "first|" })

        h.severSockets(pathPrefix: "/v1/exec/")

        io.sendStdin("second")
        io.closeStdin()
        let code = try await group.next()
        #expect(code == 0)
        #expect(await io.stdoutText() == "first|second")
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "spawn\n")
      }
    }
  }

  @Test func execMachineLostReportsPartialOutputWithDistinctExitCode() async throws {
    try await execScenario { h, m in
      let io = CLIIO()
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          await h.run(
            ["exec", "--cwd", "machines://\(m.id)/", "--", "sh", "-c", "echo part; sleep 60"],
            io: io,
          )
        }
        #expect(try await pollUntil { await io.stdoutText() == "part\n" })

        h.blockDials(pathPrefix: "/v1/machine/connect")
        h.severSockets(pathPrefix: "/v1/machine/connect")
        #expect(try await pollUntil { await h.machineListText().contains("\(m.id) detached") })
        await settleScheduledTimers()
        await h.clock.advance(by: .seconds(61))

        let code = try await group.next()
        #expect(code == 125)
        #expect(await io.stdoutText() == "part\n")
        #expect(await io.stderrText().contains("lost"))
      }
    }
  }

  @Test func killOnDetachedMachineSurfacesCancelled() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let addIO = CLIIO()
      #expect(await h.run(["machine", "add"], io: addIO) == 0)
      let id = String(await addIO.stdoutText().split(separator: "\n").map(String.init)[0].dropFirst("machine ".count))

      let io = CLIIO()
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          await h.run(["exec", "--cwd", "machines://\(id)/", "--", "sleep", "60"], io: io)
        }
        #expect(try await pollUntil { try await h.liveExecIDs().count == 1 })
        let execID = try await h.liveExecIDs()[0]
        #expect(await h.run(["kill", execID]) == 0)

        let code = try await group.next()
        #expect(code == 124)
        #expect(await io.stderrText().contains("cancelled"))
      }
    }
  }

  @Test func psListsTheLiveExecAndKillSurfacesTheSignal() async throws {
    try await execScenario { h, m in
      let io = CLIIO()
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          await h.run(["exec", "--cwd", "machines://\(m.id)/", "--", "sleep", "30"], io: io)
        }
        #expect(try await pollUntil {
          let psIO = CLIIO()
          guard await h.run(["ps"], io: psIO) == 0 else { return false }
          return await psIO.stdoutText().contains("sleep 30")
        })
        let psIO = CLIIO()
        #expect(await h.run(["ps"], io: psIO) == 0)
        let line = await psIO.stdoutText().split(separator: "\n").map(String.init)[0]
        let fields = line.split(separator: " ").map(String.init)
        #expect(fields[1] == m.id)
        let execID = fields[0]

        #expect(await h.run(["kill", execID]) == 0)
        let code = try await group.next()
        #expect(code == 143)

        #expect(try await pollUntil { try await h.liveExecIDs().isEmpty })
      }
    }
  }
}

func execScenario(_ body: @escaping @Sendable (MachineCLIHarness, JoinedMachine) async throws -> Void) async throws {
  let harness = try MachineCLIHarness()
  try await harness.runScenario { h in
    let machine = try await h.addAndJoin()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { _ = await h.run(["machine", "run"]) }
      try await h.waitAttached(machine.id)
      try await body(h, machine)
      group.cancelAll()
    }
  }
}
