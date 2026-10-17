#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.OperationError
import Synchronization

/// Why the agent or a worker stops a running exec; its verdict carries the reason.
enum StopReason: String {
  case leaving, retired, refused
}

/// Why a request for an operation cannot be answered now: the message of its `supervisorUnavailable` error.
enum Unavailable: String {
  /// The worker holding it is not connected, or a recovered worker that may hold it has an unreadable inventory.
  case workerNotConnected
  /// The worker is not the current one, so it admits no start.
  case workerNotCurrent
  /// Its worker or supervisor did not answer in time.
  case supervisorTimeout

  func error(_ operation: UUID?) -> OperationError { OperationError(.supervisorUnavailable, message: rawValue, operation: operation) }
}

/// Why an operation's outcome is unknown for good: the `reason` in the details of its `unknownOperation` error.
enum UnknownOutcome: String {
  /// Its worker dropped it before it settled.
  case workerLost
  /// A worker that died with an unreadable inventory may have held it.
  case workerUnaccounted
  /// An earlier agent's version-1 supervisor holds it.
  case supervisorNotAdopted

  func error(_ operation: UUID, message: String) -> OperationError {
    OperationError(.unknownOperation, message: message, operation: operation, details: ["outcome": "unknown", "reason": .string(rawValue)])
  }
}

/// Bounds `body`: on expiry, or when the caller is cancelled, it answers at once and cancels `body` without waiting for it, so a
/// peer that never answers holds nothing up.
func withDeadline<R: Sendable>(_ duration: Duration, operation: UUID?, _ body: @escaping @Sendable () async throws -> R) async throws -> R {
  let outcome = DeadlineOutcome<R>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      outcome.arm(continuation)
      outcome.attach(Task {
        do { outcome.resolve(.success(try await body())) } catch { outcome.resolve(.failure(error)) }
      })
      outcome.attach(Task {
        do { try await ContinuousClock().sleep(for: duration) } catch { return }
        outcome.resolve(.failure(Unavailable.supervisorTimeout.error(operation)))
      })
    }
  } onCancel: {
    outcome.resolve(.failure(CancellationError()))
  }
}

private final class DeadlineOutcome<R: Sendable>: Sendable {
  struct State {
    var continuation: CheckedContinuation<R, any Error>?
    var result: Result<R, any Error>?
    var tasks: [Task<Void, Never>] = []
  }

  let state = Mutex(State())

  func arm(_ continuation: CheckedContinuation<R, any Error>) {
    let result = state.withLock { state in
      if state.result == nil { state.continuation = continuation }
      return state.result
    }
    if let result { continuation.resume(with: result) }
  }

  func attach(_ task: Task<Void, Never>) {
    let resolved = state.withLock { state in
      if state.result == nil { state.tasks.append(task) }
      return state.result != nil
    }
    if resolved { task.cancel() }
  }

  /// The first outcome wins; it resumes the caller and cancels whatever is still running.
  func resolve(_ result: Result<R, any Error>) {
    let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<R, any Error>?, [Task<Void, Never>]) in
      guard state.result == nil else { return (nil, []) }
      state.result = result
      defer { state.continuation = nil; state.tasks = [] }
      return (state.continuation, state.tasks)
    }
    continuation?.resume(with: result)
    for task in tasks { task.cancel() }
  }
}
