#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import Testing
import TestRunner

struct BazelRunnerTests {
  @Test func failureProbe() async {
    switch ProcessInfo.processInfo.environment["BAZEL_RUNNER_PROBE"] {
    case nil: return
    case "early-exit": exit(0)
    case "detached-early-exit": await Task.detached { exit(0) }.value
    default: Issue.record("deliberate runner failure")
    }
  }

  @Test(arguments: ["issue", "early-exit", "detached-early-exit"])
  func completionReport(mode: String) throws {
    let run = try TestBinaryRun(test: "BazelRunnerTests/failureProbe()", environment: ["BAZEL_RUNNER_PROBE": mode])
    #expect(run.status != 0, "\(run.output)")
    if mode == "issue" {
      #expect(run.xml?.contains("<failure") == true, "\(run.output)")
    } else {
      #expect(run.xml == nil)
      #expect(run.output.contains("test runner exited before recording its completed result"), "\(run.output)")
    }
  }
}

#if os(macOS)
  import AppKit

  @MainActor struct BazelAppKitRunnerTests {
    @Test func failureProbe() async throws {
      guard ProcessInfo.processInfo.environment["BAZEL_RUNNER_PROBE"] == "appkit" else { return }
      NSApplication.shared.setActivationPolicy(.accessory)
      NSApplication.shared.finishLaunching()
      let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
      window.orderFrontRegardless()
      defer { window.close() }
      try await ContinuousClock().sleep(for: .milliseconds(50))
      Issue.record("deliberate AppKit runner failure")
    }

    @Test func completionReport() throws {
      let run = try TestBinaryRun(test: "BazelAppKitRunnerTests/failureProbe()", environment: ["BAZEL_RUNNER_PROBE": "appkit"])
      #expect(run.status != 0, "\(run.output)")
      #expect(run.xml?.contains("<failure") == true, "\(run.output)")
    }
  }
#endif
