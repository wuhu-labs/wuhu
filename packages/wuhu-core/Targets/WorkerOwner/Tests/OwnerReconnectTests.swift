import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct OwnerReconnectTests {
  @Test(arguments: ["/worker/hello", "/worker/upload"]) func repeatedUnavailabilityBacksOffEvenWhenHelloSucceeds(failedPath: String) async throws {
    let clock = RecordingReconnectClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let active = Mutex(false)
      let failures = Mutex(0)
      let dropped = Mutex(false)
      let effects = Mutex(0)
      let bytes = OwnerByteEndpoint(invoke: { _ in
        effects.withLock { $0 += 1 }
        return try ownerEncode(OwnerEnvelope(value: .integer(7), fault: nil))
      })
      let endpoint = try bytes.endpoint(token: "token", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
      let fetch = FetchClient { request in
        if active.withLock({ $0 }) {
          if request.url.path == failedPath, failures.withLock({ count in count += 1; return count <= 9 }) {
            return .text("500 Internal Server Error\n", status: .internalServerError)
          }
          if failedPath == "/worker/hello", request.url.path == "/worker/upload", dropped.withLock({ value in defer { value = true }; return !value }) {
            throw WorkerProtocolError(.unavailable, message: "Transport detached")
          }
        }
        return try await endpoint.handler(request)
      }
      let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
      _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
      active.withLock { $0 = true }
      let value: Int = try await OwnerRPC(client: client).call("fixture.effect", true)
      #expect(value == 7)
      #expect(effects.withLock { $0 } == 1)
      let expected = [100, 200, 400, 800, 1600, 3200, 5000, 5000, 5000] + (failedPath == "/worker/hello" ? [5000] : [])
      #expect(clock.delays == expected.map { Duration.milliseconds($0) })
      await bytes.shutdown()
    }
  }
}

private final class RecordingReconnectClock: Clock, Sendable {
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
