import ScratchTesting
import Testing

// A representative slice of this suite, rerun in a child whose TMPDIR is a fresh folder, leaves that folder empty:
// CLI homes and wallets, the m6 machine harness, upgrade layouts and a session's exec state included. Suites that
// wait on real time stay out: the child runs alongside the parent and would eat their budget.
@Suite struct TemporaryFolderLeakTests {
  @Test(.enabled(if: !LeakGuard.isChild)) func aRepresentativeRunLeavesNoTemporaryFolders() async throws {
    let run = try await LeakGuard.run(
      filter: "SecretVerbTests|UserVerbTests|SessionIdentityCLITests|EnrollmentCLITests|ServerTrustStoreTests|UpgradeCLITests|ClientServerFaithfulnessTests",
    )
    #expect(run.status == 0, "\(run.output)")
    #expect(run.ran > 0, "\(run.output)")
    #expect(run.leftovers == [], "\(run.output)")
  }
}
