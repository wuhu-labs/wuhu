import Fetch

extension Response {
  public func sse() -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream(SSEEvent.self, bufferingPolicy: .unbounded) { continuation in
      let task = Task {
        do {
          var parser = _SSEParser()

          for try await chunk in self.body.asyncBytes() {
            let events = try parser.parse(chunk)
            for event in events {
              continuation.yield(event)
            }
          }

          for event in try parser.finish() {
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
}
