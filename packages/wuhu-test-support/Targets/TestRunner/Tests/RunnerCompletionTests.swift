#if os(macOS) || os(Linux)
  import Foundation
  import Testing
  import TestRunner

  struct RunnerCompletionTests {
    private static let probe = "WUHU_RUNNER_PROBE"

    @Test func runnerFailureProbe() async {
      switch ProcessInfo.processInfo.environment[Self.probe] {
      case nil: return
      case "early-exit": await MainActor.run { () -> Void in exit(0) }
      case "detached-early-exit": await Task.detached { () -> Void in exit(0) }.value
      default: Issue.record("deliberate runner failure probe")
      }
    }

    @Test(arguments: ["issue", "early-exit", "detached-early-exit"])
    func `a failed or incomplete run fails the process`(mode: String) throws {
      guard ProcessInfo.processInfo.environment[Self.probe] == nil else { return }
      let run = try TestBinaryRun(test: "RunnerCompletionTests/runnerFailureProbe()", environment: [Self.probe: mode])
      #expect(run.status != 0, "\(run.output)")
      if mode == "issue" {
        #expect(run.xml?.contains("<failure") == true, "\(run.output)")
      } else {
        #expect(run.xml == nil)
        #expect(run.output.contains("test runner exited before recording its completed result"), "\(run.output)")
      }
    }
  }
#endif
