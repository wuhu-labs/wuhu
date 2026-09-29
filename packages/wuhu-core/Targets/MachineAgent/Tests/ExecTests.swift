import Foundation
@testable import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Testing

@Suite
struct ExecTests {
  @Test func echoRoundTrip() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["echo", "hi"]))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "hi\n")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func exitCodePassesThrough() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "exit 7"]))
      let collected = try await collect(exec)
      #expect(collected.exit == .exited(code: 7))
    }
  }

  @Test func selfSignalSurfacesAsSignaled() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "kill -TERM $$"]))
      let collected = try await collect(exec)
      #expect(collected.exit == .signaled(signal: 15))
    }
  }

  @Test func stdinHalfCloseEndsCat() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["cat"]))
      try await exec.sendStdin(Array("first ".utf8))
      try await exec.sendStdin(Array("second".utf8))
      await exec.closeStdin()
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "first second")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func cwdAndEnvApply() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let directory = scratch.path
    let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "pwd && printf %s \"$WUHU_TEST_FLAG\""],
        cwd: directory,
        env: ["WUHU_TEST_FLAG": "flagged"],
      ))
      let collected = try await collect(exec)
      let resolvedOut = collected.stdoutText.split(separator: "\n").map(String.init)
      #expect(URL(fileURLWithPath: resolvedOut[0]).resolvingSymlinksInPath().path == resolved)
      #expect(resolvedOut[1] == "flagged")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func secretValuesInjectAsEnvAndOutputIsMasked() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "printf 'token=%s;' \"$TOKEN\"; printf 'again %s|%s|' \"$TOKEN\" \"$ALIAS\" 1>&2; printf '[%s]' \"$EMPTY\""],
        secretValues: ["TOKEN": "hunter2-value", "ALIAS": "hunter2-value", "EMPTY": ""],
      ))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "token=***;[]")
      #expect(collected.stderrText == "again ***|***|")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func maskingCoversSecretValuesAndTheTokenButNeverAnEmptyValue() {
    let start = makeStart(
      execID(1),
      command: ["true"],
      secretValues: ["A": "hunter2", "B": "hunter2", "E": ""],
      session: ExecSessionCredential(token: "wst_t", spaceURL: "https://space.test"),
    )
    #expect(ExecEngine.maskedValues(start) == ["hunter2", "wst_t"])
  }

  @Test func sessionCredentialSetsTheServerNamesLastAndMasksTheToken() async throws {
    try await Harness().run { h in
      h.connect()
      let token = "wst_" + String(repeating: "9f", count: 32)
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "printf '%s|%s|%s|%s' \"$WUHU_EXEC\" \"$WUHU_SPACE_URL\" \"$WUHU_TOKEN\" \"$WUHU_IDENTITY\""],
        env: ["WUHU_EXEC": "0", "WUHU_TOKEN": "forged", "WUHU_IDENTITY": "wallet"],
        session: ExecSessionCredential(token: token, spaceURL: "https://space.test:5530"),
      ))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "1|https://space.test:5530|***|wallet")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func withoutASessionTheServerNamesAreUnset() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "printf '%s|%s|%s' \"${WUHU_EXEC-unset}\" \"${WUHU_TOKEN-unset}\" \"${WUHU_SPACE_URL-unset}\""],
        env: ["WUHU_EXEC": "1", "WUHU_TOKEN": "forged"],
      ))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "unset|unset|unset")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func anInheritedIdentityOrGroupIsDroppedUnlessTheStartSetsIt() async throws {
    let bare = ExecEngine.environmentOverlay(makeStart(execID(1), command: ["true"]))
    #expect(bare.keys.contains("WUHU_IDENTITY"))
    #expect(bare["WUHU_IDENTITY"] == .some(String?.none))
    #expect(bare["WUHU_GROUP"] == .some(String?.none))
    let own = ExecEngine.environmentOverlay(makeStart(execID(1), command: ["true"], env: ["WUHU_IDENTITY": "wallet"]))
    #expect(own["WUHU_IDENTITY"] == .some("wallet"))
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "printf %s ${WUHU_IDENTITY-unset}"]))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "unset")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  // Names come only from a server that predates group secrets; this agent has
  // nothing to resolve them from, so nothing spawns.
  @Test func secretNamesFailLoudlyWithoutSpawning() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let marker = scratch.path + "/spawned"
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["touch", marker], secrets: ["X": "GH_TOKEN"]))
      let collected = try await collect(exec)
      #expect(collected.stdout.isEmpty)
      #expect(collected.stderrText == "wuhu: secret GH_TOKEN came as a name, not a value; this machine's server predates group secrets\n")
      #expect(collected.exit == .exited(code: 127))
    }
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test func spawnFailureFailsLoudly() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sleep", "1"], cwd: "/nonexistent-cwd-for-test"))
      let collected = try await collect(exec)
      #expect(collected.stderrText.hasPrefix("wuhu: spawn failed:"))
      #expect(collected.exit == .exited(code: 127))
    }
  }

  // Across reconnects the agent says once that the file is unused, and never
  // reads, changes or removes it.
  @Test func aLegacyVaultFileIsLeftAloneAndNamedInOneLogLine() async throws {
    let logs = RecordedLogs()
    let harness = try Harness(logger: logs.logger)
    let vault = harness.stateDirectory + "/vault.json"
    let contents = Data(#"{"GH_TOKEN":"hunter2"}"#.utf8)
    #expect(FileManager.default.createFile(atPath: vault, contents: contents, attributes: [.posixPermissions: 0o600]))
    try await harness.run { h in
      for round in 1 ... 2 {
        let (_, sever) = h.connect()
        let exec = await h.caller.startExec(makeStart(execID(round), command: ["printf", "%s", "ran"]))
        let collected = try await collect(exec)
        #expect(collected.stdoutText == "ran")
        sever.close()
      }
    }
    #expect(FileManager.default.contents(atPath: vault) == contents)
    let lines = logs.messages.filter { $0.contains("vault.json") }
    #expect(lines == ["\(vault) is no longer used: an exec's secrets are its machine's group secrets (wuhu secret set)"])
  }

  @Test func withoutAVaultFileNothingIsLogged() async throws {
    let logs = RecordedLogs()
    let harness = try Harness(logger: logs.logger)
    try await harness.run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["true"]))
      _ = try await collect(exec)
    }
    #expect(!logs.messages.contains { $0.contains("vault.json") })
  }

  @Test func vfsAndSearchServeOverTheWire() async throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    try await Harness().run { h in
      h.connect()
      let written = try await retryingUntilBound {
        try await h.caller.vfs(.write(path: root + "/wire.txt", data: Base64Data(Array("alpha".utf8)), ifMatch: nil))
      }
      guard case .written = written else {
        Issue.record("expected written, got \(written)")
        return
      }
      guard case let .file(_, data) = try await h.caller.vfs(.read(path: root + "/wire.txt")) else {
        Issue.record("expected file")
        return
      }
      #expect(data.bytes == Array("alpha".utf8))
      guard case let .matches(matches, _) = try await h.caller.search(.grep(pattern: "alp", path: root, matchLimit: nil, entryLimit: nil, step: nil)) else {
        Issue.record("expected matches")
        return
      }
      #expect(matches.map(\.path) == [root + "/wire.txt"])
    }
  }
}
