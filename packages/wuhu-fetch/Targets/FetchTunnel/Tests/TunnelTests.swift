#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import FetchTunnel
import Synchronization
import Testing

private final class Link: Sendable {
  let a: AsyncThrowingStream<Bytes, any Error>.Continuation
  let b: AsyncThrowingStream<Bytes, any Error>.Continuation
  let first: TunnelTransport
  let second: TunnelTransport
  let log = Mutex<[Frame]>([])

  init() {
    let (as_, a) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (bs, b) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    self.a = a; self.b = b
    let ar = Reader(as_), br = Reader(bs)
    first = TunnelTransport(receive: { try await ar.next() }, send: { b.yield($0) }, abort: { a.finish(); b.finish() })
    second = TunnelTransport(receive: { try await br.next() }, send: { a.yield($0) }, abort: { a.finish(); b.finish() })
  }
}

private actor Reader {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    var iterator = self.iterator
    let result = try await iterator.next(isolation: self)
    self.iterator = iterator
    return result
  }
}

private func request(_ suffix: String = "a", body: Body? = nil) -> Request {
  Request(url: URL(string: "https://example.test/\(suffix)")!, method: .post, headers: .init(sensitiveValues: ["authorization": "secret"]), body: body)
}

@Test func roundTripAndMultiplex() async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first, limits: .init(chunkBytes: 2))
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    group.addTask {
      try? await Tunnel.serve(over: link.second, limits: .init(chunkBytes: 2)) { request in
        #expect(request.headers["authorization"] == "secret")
        return .init(status: .created, body: request.body ?? .empty)
      }
    }
    async let a = tunnel.client(request("a", body: .string("abcdef")))
    async let b = tunnel.client(request("b", body: .string("123456")))
    let responses = try await (a, b)
    #expect(responses.0.status == .created)
    #expect(try await responses.0.body.text() == "abcdef")
    #expect(try await responses.1.body.text() == "123456")
    await tunnel.abort()
    group.cancelAll()
  }
}

@Test func bodyAndHeadCaps() async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first, limits: .init(headBytes: 1, bodyBytes: 3))
  await #expect(throws: TunnelError.bodyTooLarge) { try await tunnel.client(request(body: .string("abcd"))) }
  await #expect(throws: TunnelError.headTooLarge) { try await tunnel.client(request()) }
  await tunnel.abort()
}

@Test func streamCapAbortAndNoReplay() async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first, limits: .init(streams: 1))
  let (arrived, arrival) = AsyncStream<Void>.makeStream()
  let reader = ReaderForVoid(arrived)
  let (blocked, blocker) = AsyncThrowingStream<Response, any Error>.makeStream()
  await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    group.addTask {
      try? await Tunnel.serve(over: link.second, limits: .init(streams: 1)) { _ in
        arrival.yield(())
        for try await response in blocked { return response }
        throw TunnelError.cancelled
      }
    }
    group.addTask {
      await #expect(throws: TunnelError.cancelled) { try await tunnel.client(request()) }
    }
    await reader.next()
    await #expect(throws: TunnelError.capacityExceeded) { try await tunnel.client(request("b")) }
    await tunnel.abort()
    blocker.finish()
    group.cancelAll()
  }
  await #expect(throws: TunnelError.cancelled) { try await tunnel.client(request()) }
  let fresh = try Tunnel(over: Link().first)
  await fresh.abort()
}

private actor ReaderForVoid {
  var iterator: AsyncStream<Void>.Iterator
  init(_ stream: AsyncStream<Void>) { iterator = stream.makeAsyncIterator() }
  func next() async { var iterator = self.iterator; _ = await iterator.next(isolation: self); self.iterator = iterator }
}

@Test func corruptionFailsInFlight() async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first)
  let peer = ReaderForFrame(link.second)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    group.addTask {
      await #expect(throws: TunnelError.corruptFraming) { try await tunnel.client(request()) }
    }
    _ = try await peer.next()
    link.a.yield(Bytes([7]))
    try await group.waitForAll()
  }
}

private actor ReaderForFrame {
  let transport: TunnelTransport
  init(_ transport: TunnelTransport) { self.transport = transport }
  func next() async throws -> Frame { try Frame.decode(try await transport.receive()!, limits: .init()) }
}

@Test(.timeLimit(.minutes(1)), arguments: [Frame.Kind.chunk, .response, .end])
func protocolErrorIsolatedAndStreamIDsNotReused(kind: Frame.Kind) async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first, limits: .init(streams: 1))
  let peer = ReaderForFrame(link.second)
  let (finished, finish) = AsyncStream<Void>.makeStream()
  let completion = ReaderForVoid(finished)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    group.addTask {
      await #expect(throws: TunnelError.protocolViolation) { try await tunnel.client(request()) }
      let response = try await tunnel.client(request("second"))
      #expect(try await response.body.text() == "healthy")
      finish.yield(())
    }
    let first = try await peer.next()
    #expect(first.kind == .request)
    while try await peer.next().kind != .end {}
    try await link.second.send(Frame(kind: kind, id: first.id, payload: kind == .end ? .init() : Bytes([1])).encoded())
    let abort = try await peer.next()
    #expect(abort.kind == .abort)
    let second = try await peer.next()
    #expect(second.kind == .request)
    #expect(second.id > first.id)
    while try await peer.next().kind != .end {}
    let response = Response.text("healthy")
    for frame in try frames(id: second.id, kind: .response, head: Head(response, count: 7), body: Bytes("healthy".utf8), limits: .init()) {
      try await link.second.send(frame.encoded())
    }
    await completion.next()
    await tunnel.abort()
    group.cancelAll()
  }
}

@Test func reconnectFailsInFlightAndNeverReplays() async throws {
  let old = Link()
  let tunnel = try Tunnel(over: old.first)
  let peer = ReaderForFrame(old.second)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    group.addTask {
      async let first = #expect(throws: TunnelError.connectionClosed) { try await tunnel.client(request("first")) }
      async let second = #expect(throws: TunnelError.connectionClosed) { try await tunnel.client(request("second")) }
      _ = await (first, second)
    }
    var ends = 0
    while ends < 2 { if try await peer.next().kind == .end { ends += 1 } }
    old.a.finish()
    old.b.finish()
    try await group.waitForAll()
  }
  let fresh = Link()
  let replacement = try Tunnel(over: fresh.first)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await replacement.run() }
    group.addTask {
      try? await Tunnel.serve(over: fresh.second) { incoming in
        #expect(incoming.url.path == "/fresh")
        return .text("fresh")
      }
    }
    let response = try await replacement.client(request("fresh"))
    #expect(try await response.body.text() == "fresh")
    await replacement.abort()
    group.cancelAll()
  }
}

@Test func cancellationSendsStreamAbort() async throws {
  let link = Link()
  let tunnel = try Tunnel(over: link.first)
  let peer = ReaderForFrame(link.second)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    let call = Task { try await tunnel.client(request()) }
    let head = try await peer.next()
    while try await peer.next().kind != .end {}
    call.cancel()
    do { _ = try await call.value; Issue.record("cancelled request succeeded") } catch {}
    let abort = try await peer.next()
    #expect(abort.kind == .abort)
    #expect(abort.id == head.id)
    #expect(String(decoding: abort.payload, as: UTF8.self) == "cancelled")
    await tunnel.abort()
    group.cancelAll()
  }
}

@Test(.timeLimit(.minutes(1))) func peerStreamCapDoesNotAbortHealthyNeighbor() async throws {
  let link = Link()
  let peer = ReaderForFrame(link.first)
  let (arrived, arrival) = AsyncStream<Void>.makeStream()
  let ready = ReaderForVoid(arrived)
  let (response, reply) = AsyncThrowingStream<Response, any Error>.makeStream()
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      try? await Tunnel.serve(over: link.second, limits: .init(streams: 1)) { _ in
        arrival.yield(())
        for try await response in response { return response }
        throw TunnelError.cancelled
      }
    }
    for frame in try frames(id: 1, kind: .request, head: Head(request(), count: 0), body: .init(), limits: .init()) {
      try await link.first.send(frame.encoded())
    }
    await ready.next()
    let secondHead = try frames(id: 2, kind: .request, head: Head(request("overflow"), count: 0), body: .init(), limits: .init())[0]
    try await link.first.send(secondHead.encoded())
    let refused = try await peer.next()
    #expect(refused.id == 2)
    #expect(refused.kind == .abort)
    #expect(String(decoding: refused.payload, as: UTF8.self) == "capacityExceeded")
    reply.yield(.text("healthy"))
    let head = try await peer.next()
    #expect(head.kind == .response)
    #expect(head.id == 1)
    while try await peer.next().kind != .end {}
    link.a.finish(); link.b.finish()
    group.cancelAll()
  }
}
