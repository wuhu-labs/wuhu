import FetchWebSocket
import Testing
@testable import WuhuAI

@Suite struct ResponsesQueueTests {
  @Test func stalledConsumerBacklogFailsAtSixteenMiBAndReleasesBytesWhenConsumed() async throws {
    let queue = ResponsesEventBuffer()
    let chunk = SSEEvent(data: String(repeating: "x", count: 1 << 20))
    for _ in 0 ..< 16 { try queue.yield(chunk) }
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "x")) }
    var iterator = queue.stream.makeAsyncIterator()
    #expect(try await iterator.next() == chunk)
    try queue.yield(chunk)
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "x")) }
    queue.finish()
  }

  @Test func emptyQueuedEventsHaveNonzeroReceiveCharge() throws {
    let queue = ResponsesEventBuffer()
    let chunk = SSEEvent(data: String(repeating: "x", count: (16 << 20) - 1))
    try queue.yield(chunk)
    try queue.yield(SSEEvent(data: ""))
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "")) }
    queue.finish()
  }
}
