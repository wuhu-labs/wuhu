@testable import CLIKit
import Testing

@Suite struct RestartHelpTests {
  @Test func restartHelpPreservesQueuedDeliveriesAndSubscriptions() throws {
    guard case let .help(text) = try Command.parse(["session", "restart", "--help"]) else {
      Issue.record("expected restart help"); return
    }
    #expect(text.contains("rows, subscriptions and timers are kept"))
    #expect(!text.contains("subscriptions and timers are cancelled"))
    #expect(!text.contains("dropped"))
  }
}
