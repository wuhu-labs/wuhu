import CLIKit
import Crypto
import Foundation
import MachineContract
import struct SpaceContract.GroupID
import SpaceCore
import Testing

@Suite struct MachineVerbFaithfulnessTests {
  @Test func machineLifecycleAddJoinRunListRotateRevoke() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let badToken = "jt_" + String(repeating: "z", count: 32)
      let badJoin = CLIIO(stdin: badToken + "\n")
      #expect(await h.run(["machine", "join", "http://machine.test:1"], io: badJoin) == 1)
      #expect(await badJoin.stderrText().contains("tokenInvalid"))

      let machine = try await h.addAndJoin()
      let config = h.home.appendingPathComponent(".wuhu/machine/agent.json")
      #expect(FileManager.default.fileExists(atPath: config.path))
      #expect(await h.machineListText() == "box \(machine.id) detached\n")

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = await h.run(["machine", "run"]) }
        try await h.waitAttached(machine.id)
        group.cancelAll()
      }

      let joinedKey = try h.boxMachineKey()
      let rotateIO = CLIIO()
      #expect(await h.run(["machine", "rotate", machine.id], io: rotateIO) == 0)
      let rotateLines = await rotateIO.stdoutText().split(separator: "\n").map(String.init)
      let newToken = String(rotateLines[0].dropFirst("token ".count))
      #expect(JoinToken.isValid(newToken))
      #expect(newToken != machine.token)
      #expect(rotateLines[1] == "fingerprint \(MachineCLIHarness.serverFingerprint)")
      let rotateHint = await rotateIO.stderrText()
      #expect(rotateHint.contains("wuhu machine join https://machine.test:1 \(MachineCLIHarness.serverFingerprint)"))
      #expect(!rotateHint.contains(newToken))
      await #expect(throws: DialRefused.self) {
        _ = try await h.dialMachineConnect(key: joinedKey)
      }
      let rejoinIO = CLIIO(stdin: newToken + "\n", terminal: true)
      #expect(await h.run(["machine", "join", "http://machine.test:1", "--name", "box"], io: rejoinIO) == 0)
      #expect(await rejoinIO.stderrText().contains("join token (stdin, end with ctrl-d): "))
      let rotatedKey = try h.boxMachineKey()
      #expect(rotatedKey.publicKey.rawRepresentation != joinedKey.publicKey.rawRepresentation)
      let admitted = try await h.dialMachineConnect(key: rotatedKey)
      admitted.close()

      let revokeIO = CLIIO()
      #expect(await h.run(["machine", "revoke", machine.id], io: revokeIO) == 0)
      #expect(await revokeIO.stdoutText() == "revoked \(machine.id)\n")
      await #expect(throws: DialRefused.self) {
        _ = try await h.dialMachineConnect(key: rotatedKey)
      }
    }
  }

  @Test func revokeKicksTheRunningAgentAndRotateRejoins() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addAndJoin()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = await h.run(["machine", "run"]) }
        try await h.waitAttached(machine.id)

        // Revocation reaches the LIVE connection: the hub kicks the leg on
        // revoke, and the agent's redials are refused at the handshake.
        #expect(await h.run(["machine", "revoke", machine.id]) == 0)
        #expect(try await pollUntil { await h.machineListText() == "box \(machine.id) detached\n" })
        group.cancelAll()
      }

      let rotateIO = CLIIO()
      #expect(await h.run(["machine", "rotate", machine.id], io: rotateIO) == 0)
      let rotateLines = await rotateIO.stdoutText().split(separator: "\n").map(String.init)
      let newToken = String(rotateLines[0].dropFirst("token ".count))
      #expect(await h.run(["machine", "join", "http://machine.test:1", "--name", "box"], io: CLIIO(stdin: newToken + "\n")) == 0)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = await h.run(["machine", "run"]) }
        try await h.waitAttached(machine.id)
        group.cancelAll()
      }
    }
  }

  @Test func machineAddPrintsTheTokenOnceWithJoinGuidance() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let io = CLIIO()
      #expect(await h.run(["machine", "add"], io: io) == 0)
      let lines = await io.stdoutText().split(separator: "\n").map(String.init)
      #expect(lines.count == 3)
      #expect(lines[0].hasPrefix("machine mc_"))
      #expect(lines[1].hasPrefix("token jt_"))
      #expect(lines[2] == "fingerprint \(MachineCLIHarness.serverFingerprint)")
      let hint = await io.stderrText()
      #expect(hint.contains("wuhu machine join https://machine.test:1 \(MachineCLIHarness.serverFingerprint)"))
      #expect(!hint.contains("jt_"))
      let listed = await h.machineListText()
      #expect(!listed.contains("jt_"))
    }
  }

  @Test func aMachineNameAddressesEveryMachineVerb() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addAndJoin()

      let renameIO = CLIIO()
      #expect(await h.run(["machine", "name", machine.id, "Studio"], io: renameIO) == 0)
      #expect(await renameIO.stdoutText() == "studio \(machine.id)\n")
      #expect(await h.machineListText() == "studio \(machine.id) detached\n")

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = await h.run(["machine", "run"]) }
        try await h.waitAttached(machine.id)

        let execIO = CLIIO()
        #expect(await h.run(["exec", "--cwd", "machines://STUDIO/", "--", "sh", "-c", "echo hi"], io: execIO) == 0)
        #expect(await execIO.stdoutText() == "hi\n")

        group.cancelAll()
      }

      let revokeIO = CLIIO()
      #expect(await h.run(["machine", "revoke", "studio"], io: revokeIO) == 0)
      #expect(await revokeIO.stdoutText() == "revoked studio\n")

      let missingIO = CLIIO()
      #expect(await h.run(["machine", "revoke", "ghost"], io: missingIO) == 1)
      #expect(await missingIO.stderrText().contains("ghost"))
    }
  }

  @Test func machineMoveHandsTheMachineToAnotherGroup() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addAndJoin()
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

  @Test func fsToolsAndSearchRouteOverMachinesAddresses() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let machine = try await h.addAndJoin()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = await h.run(["machine", "run"]) }
        try await h.waitAttached(machine.id)
        let base = "machines://\(machine.id)\(h.box.path)"

        let writeIO = CLIIO()
        #expect(await h.run(["write", "--force", "\(base)/a.md", "--body", "hello\nworld\n"], io: writeIO) == 0)
        #expect(await writeIO.stdoutText().hasPrefix("token "))

        let readIO = CLIIO()
        #expect(await h.run(["read", "\(base)/a.md"], io: readIO) == 0)
        #expect(await readIO.stdoutText() == "hello\nworld\n")

        #expect(await h.run(["edit", "\(base)/a.md", "hello", "hi"]) == 0)
        let editedIO = CLIIO()
        #expect(await h.run(["read", "\(base)/a.md"], io: editedIO) == 0)
        #expect(await editedIO.stdoutText() == "hi\nworld\n")

        let statIO = CLIIO()
        #expect(await h.run(["stat", "\(base)/a.md"], io: statIO) == 0)
        #expect(await statIO.stdoutText().contains("kind=file"))

        let lsIO = CLIIO()
        #expect(await h.run(["ls", base], io: lsIO) == 0)
        #expect(await lsIO.stdoutText().contains("a.md"))

        let grepIO = CLIIO()
        #expect(await h.run(["grep", "hi", base], io: grepIO) == 0)
        #expect(await grepIO.stdoutText().contains("\(base)/a.md:1:hi"))

        let findIO = CLIIO()
        #expect(await h.run(["find", "**/*.md", base], io: findIO) == 0)
        #expect(await findIO.stdoutText().contains("\(base)/a.md"))

        let revIO = CLIIO()
        #expect(await h.run(["read", "\(base)/a.md@1"], io: revIO) == 1)
        #expect(await revIO.stderrText().contains("unsupported"))

        #expect(await h.run(["mv", "\(base)/a.md", "\(base)/b.md"]) == 0)
        let rmIO = CLIIO()
        #expect(await h.run(["rm", "--force", "\(base)/b.md"], io: rmIO) == 0)
        #expect(await rmIO.stdoutText() == "")
        #expect(!FileManager.default.fileExists(atPath: h.box.appendingPathComponent("b.md").path))

        group.cancelAll()
      }
    }
  }
}
