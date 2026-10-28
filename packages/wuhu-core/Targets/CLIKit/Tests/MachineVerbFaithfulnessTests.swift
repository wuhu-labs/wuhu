import CLIKit
import DeterministicDependencies
import MachineContract
import struct SpaceContract.GroupID
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MachineVerbFaithfulnessTests {
  @Test func machineAddPrintsTheTokenOnceWithJoinGuidance() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let io = CLIIO()
      let code = await h.run(["machine-v2", "add", "--name", "box"], io: io)
      let stderr = await io.stderrText()
      try #require(code == 0, "\(stderr)")
      let lines = await io.stdoutText().split(separator: "\n").map(String.init)
      try #require(lines.count == 3)
      #expect(lines[0].hasPrefix("machine mc_"))
      #expect(lines[1].hasPrefix("token jt_"))
      #expect(lines[2] == "fingerprint \(MachineCLIHarness.serverFingerprint)")
      let hint = await io.stderrText()
      #expect(hint.contains("wuhu machine-v2 join https://machine.test:1 \(MachineCLIHarness.serverFingerprint)"))
      #expect(!hint.contains("jt_"))
      let listed = await h.machineListText()
      #expect(!listed.contains("jt_"))
    }
  }

  @Test func machineRecordsSupportNamesRotationAndRevocation() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addMachine()
      #expect(await h.machineListText() == "box \(machine.id) detached\n")

      let rename = CLIIO()
      #expect(await h.run(["machine", "name", machine.id, "Studio"], io: rename) == 0)
      #expect(await rename.stdoutText() == "studio \(machine.id)\n")
      #expect(await h.machineListText() == "studio \(machine.id) detached\n")

      let rotate = CLIIO()
      #expect(await h.run(["machine", "rotate", "studio"], io: rotate) == 0)
      let lines = await rotate.stdoutText().split(separator: "\n").map(String.init)
      let token = String(try #require(lines.first).dropFirst("token ".count))
      #expect(JoinToken.isValid(token))
      #expect(token != machine.token)
      #expect(lines.last == "fingerprint \(MachineCLIHarness.serverFingerprint)")
      #expect(await rotate.stderrText().contains("wuhu machine-v2 join"))
      #expect(await !rotate.stderrText().contains(token))

      let revoke = CLIIO()
      #expect(await h.run(["machine", "revoke", "studio"], io: revoke) == 0)
      #expect(await revoke.stdoutText() == "revoked studio\n")
      let missing = CLIIO()
      #expect(await h.run(["machine", "revoke", "ghost"], io: missing) == 1)
      #expect(await missing.stderrText().contains("ghost"))
    }
  }

  @Test func machineMoveHandsTheMachineToAnotherGroup() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addMachine()
      let team = try await h.space.ensurePersonalGroup(account: try await h.space.addAccount(kind: .human, name: nil).id)
      let io = CLIIO()
      #expect(await h.run(["machine", "move", machine.id, "--group", team.rawValue], io: io) == 0)
      #expect(await io.stdoutText() == "moved box to group \(team.rawValue)\n")
      #expect(try await h.space.machine(MachineID(rawValue: machine.id))?.group == team)

      let missing = CLIIO()
      #expect(await h.run(["machine", "move", "box"], io: missing) != 0)
      #expect(await missing.stderrText().contains("machine move: --group <group> is required"))
      let unknown = CLIIO()
      #expect(await h.run(["machine", "move", "box", "--group", "nowhere"], io: unknown) == 1)
    }
  }
}
