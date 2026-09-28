#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import ServeSSE
import Testing

@Suite struct ServeSSETests {
  @Test func eventSerializesFieldsAndMultilineData() {
    let event = SSEEvent.message(
      "hello\nworld",
      event: "message",
      id: "42",
      retry: 5000,
    )

    #expect(
      event.serialized
        == "event: message\nid: 42\nretry: 5000\ndata: hello\ndata: world\n\n",
    )
  }

  @Test func commentSerializesAsHeartbeat() {
    let comment = SSEEvent.comment("keepalive")

    #expect(comment.serialized == ": keepalive\n\n")
  }

  @Test func jsonEventUsesStableDefaults() throws {
    let event = try SSEEvent.json(["b": 2, "a": 1], event: "message")

    #expect(event.serialized == "event: message\ndata: {\"a\":1,\"b\":2}\n\n")
  }

  @Test func responseSetsSSEHeadersAndStreamsEvents() async throws {
    let stream = AsyncStream<SSEEvent> { continuation in
      continuation.yield(SSEEvent.comment("tick"))
      continuation.yield(SSEEvent.message("payload", event: "update"))
      continuation.finish()
    }

    let response = Response.sse(stream)

    #expect(response.status == .ok)
    #expect(response.headers[HTTPField.Name.contentType] == "text/event-stream; charset=utf-8")
    #expect(response.headers[HTTPField.Name.cacheControl] == "no-cache")
    #expect(response.headers[sseXAccelBufferingHeaderName] == "no")

    let body = try await response.body.text()
    #expect(
      body
        == ":\n\n: tick\n\nevent: update\ndata: payload\n\n",
    )
  }

  /// The shared forwarding combinator (F59): the `initial` frame is yielded
  /// first, then each source element is encoded and forwarded in order. This is
  /// the lifecycle the five observe/subscribe routes used to hand-roll.
  @Test func forwardingSeedsInitialThenForwardsEncodedDeltas() async throws {
    let source = AsyncStream<Int> { continuation in
      continuation.yield(1)
      continuation.yield(2)
      continuation.finish()
    }

    let response = Response.sse(
      initial: SSEEvent.message("snapshot", event: "init"),
      forwarding: source,
    ) { value in SSEEvent.message("d\(value)", event: "delta") }

    let body = try await response.body.text()
    #expect(
      body
        == ":\n\nevent: init\ndata: snapshot\n\nevent: delta\ndata: d1\n\nevent: delta\ndata: d2\n\n",
    )
  }

  /// A source with no initial frame forwards deltas only — the inbox-feed shape.
  @Test func forwardingWithoutInitialForwardsDeltasOnly() async throws {
    let source = AsyncStream<Int> { continuation in
      continuation.yield(7)
      continuation.finish()
    }

    let response = Response.sse(forwarding: source) { SSEEvent.message("v\($0)") }

    let body = try await response.body.text()
    #expect(body == ":\n\ndata: v7\n\n")
  }

  /// Returning `nil` from `encode` ends the stream early — the
  /// `guard let event = … else { break }` the routes relied on to stop on an
  /// encode failure. The element after the `nil` is never forwarded.
  @Test func forwardingStopsWhenEncodeReturnsNil() async throws {
    let source = AsyncStream<Int> { continuation in
      continuation.yield(1)
      continuation.yield(2) // encodes to nil → stream ends here
      continuation.yield(3) // never reached
      continuation.finish()
    }

    let response = Response.sse(forwarding: source) { value in
      value == 2 ? nil : SSEEvent.message("d\(value)")
    }

    let body = try await response.body.text()
    #expect(body == ":\n\ndata: d1\n\n")
  }

  /// A throwing source ends the stream best-effort after the elements it did
  /// yield (clients reconnect) — the prior inline `do/catch` that swallowed the
  /// error.
  @Test func forwardingSwallowsSourceError() async throws {
    struct Boom: Error {}
    let source = AsyncThrowingStream<Int, any Error> { continuation in
      continuation.yield(1)
      continuation.finish(throwing: Boom())
    }

    let response = Response.sse(forwarding: source) { SSEEvent.message("d\($0)") }

    let body = try await response.body.text()
    #expect(body == ":\n\ndata: d1\n\n")
  }

  /// The preamble is the first frame on the wire even before any event: a
  /// buffering proxy gets a body chunk immediately, so the response head is
  /// never parked behind a quiet source.
  @Test func emptySourceStillSendsThePreamble() async throws {
    let stream = AsyncStream<SSEEvent> { $0.finish() }

    let body = try await Response.sse(stream).body.text()
    #expect(body == ":\n\n")
  }

  /// An idle source keeps producing heartbeat comments so a dead connection is
  /// distinguishable from a quiet stream on both sides of the wire.
  @Test func idleSourceEmitsHeartbeats() async throws {
    let idle = AsyncStream<SSEEvent> { _ in }
    let response = Response.sse(idle, heartbeat: .milliseconds(2))

    var collected = ""
    for try await chunk in response.body.asyncBytes() {
      collected += String(decoding: chunk, as: UTF8.self)
      // Preamble plus at least two heartbeats; then stop consuming.
      if collected.count(where: { $0 == ":" }) >= 3 { break }
    }
    #expect(collected.hasPrefix(":\n\n"))
    #expect(collected.count(where: { $0 == ":" }) >= 3)
  }

  /// The source ending ends the response even though the heartbeat child is
  /// still sleeping — the group must not keep the body open.
  @Test func sourceEndEndsTheResponseDespitePendingHeartbeat() async throws {
    let source = AsyncStream<SSEEvent> { continuation in
      continuation.yield(SSEEvent.message("only"))
      continuation.finish()
    }

    let body = try await Response.sse(source, heartbeat: .seconds(3600)).body.text()
    #expect(body == ":\n\ndata: only\n\n")
  }

  /// `heartbeat: nil` disables the keepalive; the preamble stays.
  @Test func nilHeartbeatDisablesKeepalive() async throws {
    let source = AsyncStream<SSEEvent> { continuation in
      continuation.yield(SSEEvent.message("x"))
      continuation.finish()
    }

    let body = try await Response.sse(source, heartbeat: nil).body.text()
    #expect(body == ":\n\ndata: x\n\n")
  }
}
