import DeterministicDependencies
import FetchWebSocket
import Testing
@testable import WuhuAI

@Suite(.deterministicDependencies) struct ResponsesQueueTests {
  @Test func stalledConsumerBacklogFailsAtTheLimitAndReleasesBytesWhenConsumed() async throws {
    let queue = ResponsesEventBuffer(limit: 64 << 10)
    let chunk = SSEEvent(data: String(repeating: "x", count: 1 << 10))
    for _ in 0 ..< 64 { try queue.yield(chunk) }
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "x")) }
    var iterator = queue.stream.makeAsyncIterator()
    #expect(try await iterator.next() == chunk)
    try queue.yield(chunk)
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "x")) }
    queue.finish()
  }

  @Test func emptyQueuedEventsHaveNonzeroReceiveCharge() throws {
    let queue = ResponsesEventBuffer(limit: 64 << 10)
    let chunk = SSEEvent(data: String(repeating: "x", count: (64 << 10) - 1))
    try queue.yield(chunk)
    try queue.yield(SSEEvent(data: ""))
    #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { try queue.yield(SSEEvent(data: "")) }
    queue.finish()
  }
}
