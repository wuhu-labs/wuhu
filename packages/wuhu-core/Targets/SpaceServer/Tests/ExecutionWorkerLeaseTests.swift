import Dependencies
import Fetch
@testable import SpaceServer
import Synchronization
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerLeaseTests {
  @Test func repeatedLeaseEOFBacksOffInsteadOfSpinningAfterSuccessfulHello() async throws {
    let clock = LeaseRetryClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let opens = Mutex(0)
      let endpoint = try WorkerEndpoint(token: "token", hello: WorkerHello(release: "parent").retainingReplies(.init()), invoke: { _ in .null }, upload: { _, _ in }, download: { _ in
        if opens.withLock({ count in count += 1; return count <= 9 }) { return .empty }
        throw WorkerProtocolError(.invalidConfiguration, message: "End fixture")
      })
      let fetch = FetchClient { try await endpoint.handler($0) }
      let client = try WorkerClient(socket: "/private/parent.sock", token: "token", control: fetch, bytes: fetch)
      _ = try await client.negotiate(WorkerHello(release: "worker").retainingReplies(.init()))
      do {
        try await ExecutionWorker.keepOwnerLease(client)
        Issue.record("Lease fixture did not terminate")
      } catch let error as WorkerProtocolError { #expect(error.code == .invalidConfiguration) }
      #expect(opens.withLock { $0 } == 10)
      #expect(clock.delays == [100, 200, 400, 800, 1600, 3200, 5000, 5000, 5000].map { Duration.milliseconds($0) })
    }
  }
}

private final class LeaseRetryClock: Clock, Sendable {
  typealias Instant = ContinuousClock.Instant
  private struct State { var now = ContinuousClock().now; var delays: [Duration] = [] }
  private let state = Mutex(State())
  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .nanoseconds(1) }
  var delays: [Duration] { state.withLock { $0.delays } }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    state.withLock { value in
      value.delays.append(value.now.duration(to: deadline))
      value.now = deadline
    }
  }
}
