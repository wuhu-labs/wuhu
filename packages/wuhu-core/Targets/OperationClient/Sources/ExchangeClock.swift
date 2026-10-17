import struct OperationProtocol.OperationClock

struct ExchangeClock: Clock {
  struct Instant: InstantProtocol {
    let offset: Duration
    func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
    func duration(to other: Self) -> Duration { other.offset - offset }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
  }

  let source: OperationClock
  init(_ source: OperationClock) { self.source = source }
  var now: Instant { Instant(offset: source.now()) }
  var minimumResolution: Duration { .nanoseconds(1) }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    do { try await source.sleep(max(.zero, deadline.offset - source.now())) }
    catch is CancellationError {
      // Cancelling an OperationClock sleep disables that timer, not its exchange.
      let (parking, continuation) = AsyncStream<Void>.makeStream()
      for await _ in parking {}
      continuation.finish()
      throw CancellationError()
    }
  }
}
