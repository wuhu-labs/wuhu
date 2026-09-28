import Foundation

// MARK: - Inference

/// A single in-flight inference, surfaced two ways:
///
/// - ``stream()`` — the live event feed, as a typed-throwing `AsyncSequence`
///   you can watch. It yields events ending in ``InferenceEvent/done(_:_:)``,
///   throws ``InferenceError`` on failure, and throws ``InferenceError/cancelled``
///   if the consuming task is cancelled.
/// - ``collect()`` — runs to completion and returns the final message.
///
/// Both drive the underlying endpoint's cold event stream, so an `Inference`
/// is single-use: consume it once, via `stream()` or `collect()`.
public struct Inference: Sendable {
  let source: AsyncStream<Result<InferenceEvent, InferenceError>>

  init(source: AsyncStream<Result<InferenceEvent, InferenceError>>) {
    self.source = source
  }

  /// Watch the live event stream. Iteration throws ``InferenceError`` — and
  /// ``InferenceError/cancelled`` when the consuming task is cancelled, which
  /// also tears down the underlying request.
  public func stream() -> some AsyncSequence<InferenceEvent, InferenceError> {
    EventStream(base: source)
  }

  /// Run the inference to completion and return the final assistant message.
  ///
  /// Throws the underlying ``InferenceError`` on failure, or
  /// ``InferenceError/cancelled`` if the task is cancelled mid-flight.
  public func collect() async throws(InferenceError) -> AssistantMessage {
    for await result in source {
      switch result {
      case let .success(event):
        if case let .done(message, _) = event { return message }
      case let .failure(error):
        throw error
      }
    }
    // The source finished without a terminal event: the only way a dialect
    // parser reaches a clean end is task cancellation (otherwise it emits
    // `.done` or a `.failure`).
    throw .cancelled
  }
}

// MARK: - Typed-throwing adapter (internal)

/// Adapts the cold `AsyncStream<Result<…>>` into a typed-throwing sequence:
/// `.failure` becomes a thrown error, and a finish without a terminal `.done`
/// (i.e. cancellation) becomes ``InferenceError/cancelled``. Kept private —
/// `stream()` exposes it only as `some AsyncSequence`.
private struct EventStream: AsyncSequence {
  typealias Element = InferenceEvent
  typealias Failure = InferenceError

  let base: AsyncStream<Result<InferenceEvent, InferenceError>>

  func makeAsyncIterator() -> Iterator {
    Iterator(base: base.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: AsyncStream<Result<InferenceEvent, InferenceError>>.Iterator
    var finished = false
    var sawTerminal = false

    mutating func next() async throws(InferenceError) -> InferenceEvent? {
      if finished { return nil }
      guard let result = await base.next() else {
        finished = true
        guard sawTerminal else { throw .cancelled }
        return nil
      }
      switch result {
      case let .success(event):
        if case .done = event { sawTerminal = true }
        return event
      case let .failure(error):
        finished = true
        sawTerminal = true
        throw error
      }
    }
  }
}
