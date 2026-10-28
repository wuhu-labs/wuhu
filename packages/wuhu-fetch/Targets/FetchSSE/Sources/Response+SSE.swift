import Fetch

extension Response {
  public func sse() -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream(SSEEvent.self, bufferingPolicy: .unbounded) { continuation in
      let task = Task {
        do {
          for try await event in self.sseEvents() {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      // A consumer walking away must reach the transport: cancelling the
      // reader tears down the body stream, which is how the server side of an
      // in-process (or keep-alive) connection learns the client disconnected.
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The body's events, read no faster than they are taken. Each event's `id`
  /// is the stream's last event id so far, starting from `lastEventID` (the one
  /// a reconnect sent); nil once an empty `id:` resets it.
  public func sseEvents(after lastEventID: String? = nil) -> SSEEvents {
    SSEEvents(body: self.body, lastEventID: lastEventID)
  }
}

public struct SSEEvents: AsyncSequence, Sendable {
  let body: Body
  let lastEventID: String?

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(bytes: self.body.asyncBytes().makeAsyncIterator(), parser: _SSEParser(lastEventID: self.lastEventID))
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    var bytes: BodyStream.AsyncIterator
    var parser: _SSEParser
    var parsed: [SSEEvent] = []
    var ended = false

    public mutating func next() async throws -> SSEEvent? {
      while self.parsed.isEmpty, !self.ended {
        if let chunk = try await self.bytes.next() {
          self.parsed = try self.parser.parse(chunk).reversed()
        } else {
          self.parsed = try self.parser.finish().reversed()
          self.ended = true
        }
      }
      return self.parsed.popLast()
    }
  }
}
