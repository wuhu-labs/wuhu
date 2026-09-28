import Foundation
import Testing

@Suite struct SecretVerbTests {
  @Test func setListRemoveReachTheSpaceStoreAndNeverPrintAValue() async throws {
    let harness = try MachineCLIHarness()
    try await harness.runScenario { h in
      let setIO = CLIIO(stdin: "ghp_live_value\n")
      #expect(await h.run(["secret", "set", "GITHUB_TOKEN"], io: setIO) == 0)
      #expect(await setIO.stdoutText() == "set GITHUB_TOKEN\n")
      let first = try await h.secrets.value(of: "GITHUB_TOKEN")
      #expect(first == "ghp_live_value")

      let promptIO = CLIIO(stdin: "second\r\n", terminal: true)
      #expect(await h.run(["secret", "set", "OTHER"], io: promptIO) == 0)
      #expect(await promptIO.stderrText().contains("value for OTHER"))
      let second = try await h.secrets.value(of: "OTHER")
      #expect(second == "second")

      let listIO = CLIIO()
      #expect(await h.run(["secret", "list"], io: listIO) == 0)
      #expect(await listIO.stdoutText() == "GITHUB_TOKEN\nOTHER\n")

      let removeIO = CLIIO()
      #expect(await h.run(["secret", "remove", "OTHER"], io: removeIO) == 0)
      #expect(await removeIO.stdoutText() == "removed OTHER\n")
      let names = try await h.secrets.names()
      #expect(names == ["GITHUB_TOKEN"])

      let missingIO = CLIIO()
      #expect(await h.run(["secret", "remove", "OTHER"], io: missingIO) == 1)
      #expect(await missingIO.stderrText().contains("no secret named OTHER"))

      let invalidIO = CLIIO(stdin: "x")
      #expect(await h.run(["secret", "set", "1BAD"], io: invalidIO) == 1)
      #expect(await invalidIO.stderrText().contains("invalid secret name"))
    }
  }
}
