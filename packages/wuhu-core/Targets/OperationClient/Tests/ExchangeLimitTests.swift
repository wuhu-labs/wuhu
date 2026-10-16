#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Fetch
@testable import OperationClient
import OperationProtocol
import Synchronization
import Testing

@Suite struct ExchangeLimitTests {
  /// `exchangeLimit` cuts one call's deadline below its normal bound and never extends it.
  @Test func exchangeLimitCutsTheDeadlineAndNeverExtendsIt() async throws {
    let clock = TestClock<Duration>(); let origin = clock.now; let sleeps = Mutex(0)
    let time = OperationClock(now: { origin.duration(to: clock.now) }, sleep: { duration in
      sleeps.withLock { $0 += 1 }; try await clock.sleep(for: duration)
    })
    let client = try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: .init { _ in
      try await Task.sleep(for: .seconds(3600)); throw CancellationError()
    }, clock: time, store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    func expire(after duration: Duration, limit: Duration?) async throws {
      let before = sleeps.withLock { $0 }
      let done = Mutex(false)
      let call = Task {
        do { _ = try await client.describe("phone", exchangeLimit: limit); Issue.record("hanging describe answered") }
        catch let error as OperationError { #expect(error.code == .requestDeadline) }
        catch { Issue.record("unexpected \(error)") }
        done.withLock { $0 = true }
      }
      while sleeps.withLock({ $0 }) == before { await Task.yield() }
      await clock.advance(by: duration - .milliseconds(1))
      for _ in 0 ..< 100 { await Task.yield() }
      #expect(!done.withLock { $0 }, "expired before \(duration)")
      await clock.advance(by: .milliseconds(1))
      await call.value
    }
    try await expire(after: .milliseconds(200), limit: .milliseconds(200))
    try await expire(after: .seconds(5), limit: .seconds(60))
    await client.shutdown()
  }
}
