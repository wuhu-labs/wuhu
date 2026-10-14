#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import FetchTunnel
import Synchronization
import Testing

private actor Pull<Element: Sendable> {
  var iterator: AsyncThrowingStream<Element, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Element, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Element? {
    var iterator = self.iterator
    let value = try await iterator.next(isolation: self)
    self.iterator = iterator
    return value
  }
}

private final class Probe: Sendable {
  let aborted = Mutex(false)
  let calls = Mutex(0)
}

private final class ControlledPeer: Sendable {
  let transport: TunnelTransport
  let input: AsyncThrowingStream<Bytes, any Error>.Continuation
  let release: AsyncThrowingStream<Void, any Error>.Continuation
  let sent: Pull<Frame>
  let read: Pull<Void>
  let probe = Probe()

  init(stall: Bool = true) {
    let (inputStream, input) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (sentStream, sent) = AsyncThrowingStream<Frame, any Error>.makeStream()
    let (releaseStream, release) = AsyncThrowingStream<Void, any Error>.makeStream()
    let (readStream, read) = AsyncThrowingStream<Void, any Error>.makeStream()
    let receiver = Pull(inputStream), gate = Pull(releaseStream)
    let probe = self.probe
    self.input = input; self.release = release
    self.sent = Pull(sentStream); self.read = Pull(readStream)
    transport = TunnelTransport(receive: {
      let bytes = try await receiver.next()
      read.yield(())
      return bytes
    }, send: {
      sent.yield(try Frame.decode($0, limits: .init()))
      if stall { _ = try await gate.next() }
    }, abort: {
      probe.aborted.withLock { $0 = true }
      input.finish(); release.finish(); sent.finish(); read.finish()
    })
  }

  func send(_ frame: Frame) { input.yield(frame.encoded()) }
  func consumed(_ count: Int) async throws { for _ in 0 ..< count { _ = try await read.next() } }
}

private func opening(_ id: UInt64, body: Bytes = .init()) throws -> [Frame] {
  let request = Request(url: .init(string: "https://example.test/\(id)")!, body: .bytes(body))
  return try frames(id: id, kind: .request, head: Head(request, count: body.count), body: body, limits: .init())
}

@Test(.timeLimit(.minutes(1))) func earlyResponseDiscardsUnsentRequestFrames() async throws {
  let peer = ControlledPeer()
  let tunnel = try Tunnel(over: peer.transport, limits: .init(chunkBytes: 1, streams: 1))
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    let first = Task { try await tunnel.client(Request(url: .init(string: "https://example.test/first")!, body: .string("body"))) }
    let head = try #require(await peer.sent.next())
    #expect(head.kind == .request)
    for frame in try frames(id: head.id, kind: .response, head: Head(Response(status: .ok), count: 0), body: .init(), limits: .init()) { peer.send(frame) }
    _ = try await first.value
    let second = Task { try await tunnel.client(Request(url: .init(string: "https://example.test/second")!)) }
    peer.release.yield(())
    let next = try #require(await peer.sent.next())
    #expect(next.kind == .request)
    #expect(next.id > head.id)
    await tunnel.abort()
    _ = try? await second.value
    group.cancelAll()
  }
}

@Test(.timeLimit(.minutes(1))) func abortedHandlerRetainsAdmissionSlot() async throws {
  let peer = ControlledPeer(stall: false)
  let probe = Probe()
  let (arrivals, arrived) = AsyncThrowingStream<Void, any Error>.makeStream()
  let arrival = Pull(arrivals)
  let (held, release) = AsyncThrowingStream<Void, any Error>.makeStream()
  let blocker = Task { for try await _ in held {} }
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      try? await Tunnel.serve(over: peer.transport, limits: .init(streams: 2)) { _ in
        probe.calls.withLock { $0 += 1 }
        arrived.yield(())
        _ = try? await blocker.value
        return Response(status: .ok)
      }
    }
    for frame in try opening(1) { peer.send(frame) }
    _ = try await arrival.next()
    peer.send(Frame(kind: .abort, id: 1))
    peer.send(try opening(2)[0])
    peer.send(try opening(3)[0])
    peer.send(Frame(kind: .chunk, id: 4, payload: Bytes([1])))
    let refused = try #require(await peer.sent.next())
    #expect(refused.kind == .abort)
    #expect(refused.id == 3)
    #expect(String(decoding: refused.payload, as: UTF8.self) == "capacityExceeded")
    #expect(probe.calls.withLock { $0 } == 1)
    peer.transport.abort(); release.finish()
    group.cancelAll()
  }
  _ = try? await blocker.value
}

@Test(.timeLimit(.minutes(1))) func oversizedOpeningHeadConsumesID() async throws {
  let peer = ControlledPeer(stall: false)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await Tunnel.serve(over: peer.transport, limits: .init(headBytes: 256)) { _ in Response(status: .ok) } }
    peer.send(Frame(kind: .request, id: 1, payload: Bytes(repeating: 32, count: 257)))
    let oversized = try #require(await peer.sent.next())
    #expect(oversized.kind == .abort)
    #expect(String(decoding: oversized.payload, as: UTF8.self) == "headTooLarge")
    for frame in try opening(1) { peer.send(frame) }
    let reused = try #require(await peer.sent.next())
    #expect(reused.kind == .abort)
    #expect(String(decoding: reused.payload, as: UTF8.self) == "protocolViolation")
    peer.transport.abort()
    group.cancelAll()
  }
}

@Test(.timeLimit(.minutes(1))) func pendingAbortCoalescesWithoutLosingFairness() async throws {
  let peer = ControlledPeer()
  let tunnel = try Tunnel(over: peer.transport, limits: .init(streams: 4))
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try? await tunnel.run() }
    peer.send(Frame(kind: .chunk, id: 10))
    _ = try await peer.sent.next()
    for id: UInt64 in [11, 12, 11, 13] { peer.send(Frame(kind: .chunk, id: id)) }
    try await peer.consumed(5)
    peer.release.yield(())
    #expect(try await peer.sent.next()?.id == 11)
    peer.release.yield(())
    #expect(try await peer.sent.next()?.id == 12)
    await tunnel.abort()
    group.cancelAll()
  }
}

@Test(.timeLimit(.minutes(1))) func abortBudgetClosesInsteadOfGrowingQueue() async throws {
  let peer = ControlledPeer()
  let tunnel = try Tunnel(over: peer.transport, limits: .init(streams: 1))
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await #expect(throws: TunnelError.capacityExceeded) { try await tunnel.run() } }
    peer.send(Frame(kind: .chunk, id: 10))
    _ = try await peer.sent.next()
    peer.send(Frame(kind: .chunk, id: 11))
    peer.send(Frame(kind: .chunk, id: 12))
    peer.input.finish()
    try await group.waitForAll()
    #expect(peer.probe.aborted.withLock { $0 })
  }
}
