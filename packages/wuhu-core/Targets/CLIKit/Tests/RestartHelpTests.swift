@testable import CLIKit
import DeterministicDependencies
import Testing

@Suite(.deterministicDependencies) struct RestartHelpTests {
  @Test func groupTargetParsesForCreateAndStartOverAndRefusesMixedTargets() throws {
    guard case let .sessionCreate(create) = try Command.parse(["session", "create", "--model-group", "work", "--effort", "high", "coder"]),
          case let .sessionRestart(restart) = try Command.parse(["session", "restart", "--model-group", "work", "session-id"])
    else { Issue.record("expected group target commands"); return }
    #expect(create.modelGroup == "work")
    #expect(create.provider == nil && create.model == nil)
    #expect(create.effort == "high")
    #expect(restart.modelGroup == "work")
    #expect(try Command.parse(["session", "inspect", "session-id"]) == .sessionInspect(id: "session-id"))
    for verb in ["create", "restart"] {
      for flag in ["--provider", "--model"] {
        #expect(throws: (any Error).self) {
          try Command.parse(["session", verb, "--model-group", "work", flag, "concrete", "title-or-id"])
        }
      }
    }
  }

  @Test func restartHelpPreservesQueuedDeliveriesAndSubscriptions() throws {
    guard case let .help(text) = try Command.parse(["session", "restart", "--help"]) else {
      Issue.record("expected restart help"); return
    }
    #expect(text.contains("rows, subscriptions and timers are kept"))
    #expect(!text.contains("subscriptions and timers are cancelled"))
    #expect(!text.contains("dropped"))
  }
}
