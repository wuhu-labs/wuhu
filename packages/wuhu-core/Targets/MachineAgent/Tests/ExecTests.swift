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

  @Test func secretsInjectAsEnvAndOutputIsMasked() async throws {
    try await Harness().run { h in
      h.connect()
      let outcome = try await retryingUntilBound { try await h.caller.vaultSet(name: "GH_TOKEN", value: "hunter2-value") }
      guard case .ok = outcome else {
        Issue.record("expected ok, got \(outcome)")
        return
      }
      let exec = await h.caller.startExec(makeStart(
        execID(1),
        command: ["sh", "-c", "printf 'token=%s;' \"$TOKEN\"; printf 'again %s' \"$TOKEN\" 1>&2"],
        secrets: ["TOKEN": "GH_TOKEN"],
      ))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "token=***;")
      #expect(collected.stderrText == "again ***")
      #expect(collected.exit == .exited(code: 0))
    }
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
    let bare = ExecEngine.environmentOverlay(makeStart(execID(1), command: ["true"]), secrets: [:])
    #expect(bare.keys.contains("WUHU_IDENTITY"))
    #expect(bare["WUHU_IDENTITY"] == .some(String?.none))
    #expect(bare["WUHU_GROUP"] == .some(String?.none))
    let own = ExecEngine.environmentOverlay(makeStart(execID(1), command: ["true"], env: ["WUHU_IDENTITY": "wallet"]), secrets: [:])
    #expect(own["WUHU_IDENTITY"] == .some("wallet"))
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["sh", "-c", "printf %s ${WUHU_IDENTITY-unset}"]))
      let collected = try await collect(exec)
      #expect(collected.stdoutText == "unset")
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func unknownSecretFailsLoudlyWithoutSpawning() async throws {
    try await Harness().run { h in
      h.connect()
      let exec = await h.caller.startExec(makeStart(execID(1), command: ["echo", "never"], secrets: ["X": "MISSING"]))
      let collected = try await collect(exec)
      #expect(collected.stdout.isEmpty)
      #expect(collected.stderrText == "wuhu: unknown secret name 'MISSING'\n")
      #expect(collected.exit == .exited(code: 127))
    }
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

  @Test func vaultOpsServeOverTheWire() async throws {
    try await Harness().run { h in
      h.connect()
      _ = try await retryingUntilBound { try await h.caller.vaultSet(name: "B_TOKEN", value: "b") }
      _ = try await h.caller.vaultSet(name: "A_TOKEN", value: "a")
      guard case let .names(_, names) = try await h.caller.vaultList() else {
        Issue.record("expected names")
        return
      }
      #expect(names == ["A_TOKEN", "B_TOKEN"])
      _ = try await h.caller.vaultRemove(name: "B_TOKEN")
      guard case let .names(_, remaining) = try await h.caller.vaultList() else {
        Issue.record("expected names")
        return
      }
      #expect(remaining == ["A_TOKEN"])
      let attributes = try FileManager.default.attributesOfItem(atPath: h.stateDirectory + "/vault.json")
      #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
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
