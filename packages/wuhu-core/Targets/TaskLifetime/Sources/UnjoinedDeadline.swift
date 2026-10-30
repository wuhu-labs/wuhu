import protocol Clocks.NonsendingClock
import Synchronization

public func withUnjoinedDeadline<Value: Sendable, C: NonsendingClock>(
  _ name: String, within duration: Duration, clock: C, scope: TaskScope, isolation: isolated (any Actor)? = #isolation,
  operation: @escaping @Sendable () async throws -> Value,
) async throws -> Value where C.Duration == Duration {
  let answer = DeadlineAnswer<Value>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      answer.arm(continuation)
      do {
        let worker = try scope.run(name) {
          do { answer.fire(.success(try await operation())) }
          catch { answer.fire(.failure(error)) }
        }
        do {
          let timer = try scope.run(name + "-deadline") {
            do {
              try await clock.sleep(until: clock.now.advanced(by: max(.zero, duration)), tolerance: nil, isolation: isolation)
              answer.fire(.failure(DeadlineExceeded()))
            } catch {
              if !Task.isCancelled { answer.fire(.failure(error)) }
            }
          }
          answer.onFire { worker.cancel(); timer.cancel() }
        } catch {
          worker.cancel()
          answer.fire(.failure(error))
        }
      } catch { answer.fire(.failure(error)) }
    }
  } onCancel: { answer.fire(.failure(CancellationError())) }
}

private final class DeadlineAnswer<Value: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Value, any Error>?
    var result: Result<Value, any Error>?
    var cancel: (@Sendable () -> Void)?
  }

  private let state = Mutex(State())

  func arm(_ continuation: CheckedContinuation<Value, any Error>) {
    let result = state.withLock { state -> Result<Value, any Error>? in
      if let result = state.result { return result }
      state.continuation = continuation
      return nil
    }
    if let result { continuation.resume(with: result) }
  }

  func onFire(_ cancel: @escaping @Sendable () -> Void) {
    let fired = state.withLock { state in
      if state.result != nil { return true }
      state.cancel = cancel
      return false
    }
    if fired { cancel() }
  }

  func fire(_ result: Result<Value, any Error>) {
    let (continuation, cancel) = state.withLock { state in
      guard state.result == nil else { return (nil as CheckedContinuation<Value, any Error>?, nil as (@Sendable () -> Void)?) }
      state.result = result
      defer { state.continuation = nil; state.cancel = nil }
      return (state.continuation, state.cancel)
    }
    continuation?.resume(with: result)
    cancel?()
  }
}
