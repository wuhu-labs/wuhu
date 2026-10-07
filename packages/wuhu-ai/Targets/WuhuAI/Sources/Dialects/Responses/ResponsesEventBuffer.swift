import FetchWebSocket
import Synchronization

final class ResponsesEventBuffer: Sendable {
  let stream: ResponsesEventStream
  private let continuation: AsyncThrowingStream<SSEEvent, any Error>.Continuation
  private let bytes: ResponsesBufferedBytes
  private let terminal = Mutex<Completion?>(nil)
  private let limit = 16 << 20

  struct Completion: Sendable {
    var responseID: String
    var continuable: Bool
  }

  var completion: Completion? { terminal.withLock { $0 } }

  func complete(responseID: String, continuable: Bool) {
    terminal.withLock { $0 = Completion(responseID: responseID, continuable: continuable) }
    continuation.finish()
  }

  init() {
    let events = AsyncThrowingStream<SSEEvent, any Error>.makeStream()
    let bytes = ResponsesBufferedBytes()
    self.bytes = bytes
    continuation = events.continuation
    stream = ResponsesEventStream(base: events.stream, bytes: bytes)
  }

  func yield(_ event: SSEEvent) throws {
    let charge = Swift.max(1, event.data.utf8.count)
    let accepted = bytes.counter.withLock { bytes in
      guard charge <= limit - bytes else { return false }
      bytes += charge
      return true
    }
    guard accepted else { throw WebSocketError.limitExceeded(.bufferedReceive) }
    if case .terminated = continuation.yield(event) { bytes.counter.withLock { $0 -= charge } }
  }

  func finish(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }
}

struct ResponsesEventStream: AsyncSequence, Sendable {
  let base: AsyncThrowingStream<SSEEvent, any Error>
  let bytes: ResponsesBufferedBytes

  struct AsyncIterator: AsyncIteratorProtocol {
    var base: AsyncThrowingStream<SSEEvent, any Error>.Iterator
    let bytes: ResponsesBufferedBytes
    mutating func next() async throws -> SSEEvent? {
      guard let event = try await base.next() else { return nil }
      bytes.counter.withLock { $0 -= Swift.max(1, event.data.utf8.count) }
      return event
    }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: base.makeAsyncIterator(), bytes: bytes) }
}

final class ResponsesBufferedBytes: Sendable { let counter = Mutex(0) }
