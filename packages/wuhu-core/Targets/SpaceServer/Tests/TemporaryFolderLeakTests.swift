import ScratchTesting
import Testing

// A representative slice of this suite, rerun in a child whose TMPDIR is a fresh folder, leaves that folder empty:
// spaces, secret stores, web app folders and space files included. Suites that wait on real time stay out: the
// child runs alongside the parent and would eat their budget.
@Suite struct TemporaryFolderLeakTests {
  @Test(.enabled(if: !LeakGuard.isChild)) func aRepresentativeRunLeavesNoTemporaryFolders() async throws {
    let run = try await LeakGuard.run(
      filter: "ClaudeCodeRunTests|ClaudeCodeExecutorTests|FrozenPromptTests|SecretRoutesTests|ServeSmokeTests|WebAppTests|WebAppDirectoryLoadTests|WebPushRuntimeTests|Wuhu45MigrationTests",
    )
    #expect(run.status == 0, "\(run.output)")
    #expect(run.ran > 0, "\(run.output)")
    #expect(run.leftovers == [], "\(run.output)")
  }
}
