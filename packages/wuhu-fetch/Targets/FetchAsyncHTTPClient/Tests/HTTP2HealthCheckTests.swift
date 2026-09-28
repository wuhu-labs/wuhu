import AsyncHTTPClient
import FetchAsyncHTTPClient
import NIOCore
import NIOEmbedded
import NIOHTTP2
import Synchronization
import Testing

@Suite struct HTTP2HealthCheckTests {
  @Test func idleConnectionsAreNotProbed() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.advance(.hours(1))
    #expect(peer.frames.isEmpty)
    #expect(peer.channel.isActive)
  }

  @Test func matchingAcknowledgementsKeepAnActiveConnectionAlive() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.advance(.seconds(29))
    #expect(peer.frames.isEmpty)
    peer.advance(.seconds(1))
    let first = try #require(peer.ping())
    peer.receive(.ping(first, ack: true))
    peer.advance(.seconds(30))
    let second = try #require(peer.ping())
    #expect(second != first)
    peer.receive(.ping(second, ack: true))
    peer.advance(.seconds(10))
    #expect(peer.channel.isActive)
  }

  @Test func aMissingAcknowledgementClosesOnlyTheUnresponsiveConnection() throws {
    let dead = try HealthCheckPeer()
    let healthy = try HealthCheckPeer()
    defer { dead.finish(); healthy.finish() }
    dead.openStream(1)
    dead.openStream(3)
    healthy.openStream(1)
    dead.advance(.seconds(30))
    healthy.advance(.seconds(30))
    healthy.receive(.ping(try #require(healthy.ping()), ack: true))
    dead.advance(.seconds(9))
    #expect(dead.channel.isActive)
    dead.advance(.seconds(1))
    healthy.advance(.seconds(10))
    #expect(!dead.channel.isActive)
    #expect(healthy.channel.isActive)
  }

  @Test func inboundTrafficPostponesTheProbe() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.advance(.seconds(20))
    peer.receive(.settings(.ack))
    peer.advance(.seconds(29))
    #expect(peer.frames.isEmpty)
    peer.advance(.seconds(1))
    #expect(peer.ping() != nil)
  }

  @Test func outboundTrafficDoesNotPostponeTheProbe() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.advance(.seconds(20))
    try peer.channel.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .settings(.ack))).wait()
    peer.writes.frames.removeAll()
    peer.advance(.seconds(10))
    #expect(peer.ping() != nil)
  }

  @Test func aLateWriteFailureFromACancelledProbeDoesNotCloseTheConnection() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.writes.completion = .blocked
    peer.openStream(1)
    peer.advance(.seconds(30))
    let old = try #require(peer.ping())
    peer.closeStream(1)
    peer.openStream(3)
    peer.writes.completion = .succeeded
    peer.advance(.seconds(30))
    let current = try #require(peer.ping())
    #expect(current != old)
    peer.writes.releaseBlockedWrites()
    #expect(peer.channel.isActive)
    peer.receive(.ping(current, ack: true))
  }

  @Test func wrongAndStaleAcknowledgementsAndOtherFramesDoNotSatisfyAProbe() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.advance(.seconds(30))
    let first = try #require(peer.ping())
    peer.receive(.ping(first, ack: true))
    peer.advance(.seconds(30))
    let second = try #require(peer.ping())
    #expect(first != second)
    peer.receive(.ping(first, ack: true))
    peer.receive(.ping(second, ack: false))
    peer.receive(.settings(.ack))
    peer.advance(.seconds(10))
    #expect(!peer.channel.isActive)
  }

  @Test func completingTheLastStreamCancelsAnOutstandingProbe() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.openStream(3)
    peer.advance(.seconds(30))
    let old = try #require(peer.ping())
    peer.closeStream(1)
    peer.advance(.seconds(9))
    peer.closeStream(3)
    peer.advance(.seconds(60))
    #expect(peer.channel.isActive)
    #expect(peer.frames.isEmpty)
    peer.openStream(5)
    peer.advance(.seconds(30))
    #expect(try #require(peer.ping()) != old)
  }

  @Test func aBlockedPingWriteStillHasADeadline() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.writes.completion = .blocked
    peer.openStream(1)
    peer.advance(.seconds(40))
    #expect(!peer.channel.isActive)
    #expect(peer.ping() != nil)
  }

  @Test func aFailedPingWriteClosesTheConnectionImmediately() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.writes.completion = .failed
    peer.openStream(1)
    peer.advance(.seconds(30))
    #expect(!peer.channel.isActive)
  }

  @Test func closureCancelsScheduledProbes() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    try peer.channel.close().wait()
    peer.advance(.hours(1))
    #expect(peer.frames.isEmpty)
  }

  @Test func preservesExistingInitializerAndInstallingTwiceDoesNotDuplicateProbes() throws {
    let calls = Mutex(0)
    var configuration = HTTPClient.Configuration()
    configuration.http2ConnectionDebugInitializer = { channel in
      calls.withLock { $0 += 1 }
      return channel.eventLoop.makeSucceededVoidFuture()
    }
    configuration.enableHTTP2HealthChecks(idleInterval: .seconds(60))
    configuration.enableHTTP2HealthChecks(idleInterval: .seconds(30))
    let peer = try HealthCheckPeer(configuration: configuration)
    defer { peer.finish() }
    #expect(calls.withLock { $0 } == 1)
    peer.openStream(1)
    peer.advance(.seconds(30))
    #expect(peer.ping() != nil)
    #expect(peer.frames.isEmpty)
  }

  @Test func preservesAnExistingInitializerFailure() throws {
    var configuration = HTTPClient.Configuration()
    configuration.http2ConnectionDebugInitializer = { channel in
      channel.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }
    configuration.enableHTTP2HealthChecks()
    let channel = EmbeddedChannel(handler: NIOHTTP2Handler(mode: .client))
    defer { _ = try? channel.finish() }
    let initialize = try #require(configuration.http2ConnectionDebugInitializer)
    #expect(throws: ChannelError.operationUnsupported) {
      try initialize(channel).wait()
    }
  }

  @Test func forwardsFramesAndStreamEventsIncludingGoAwayUnchanged() throws {
    let peer = try HealthCheckPeer()
    defer { peer.finish() }
    peer.openStream(1)
    peer.receive(.goAway(lastStreamID: 1, errorCode: .protocolError, opaqueData: nil))
    peer.closeStream(1)
    let frame = try #require(try peer.channel.readInbound(as: HTTP2Frame.self))
    guard case let .goAway(lastStreamID, errorCode, _) = frame.payload else {
      Issue.record("GOAWAY was not forwarded")
      return
    }
    #expect(lastStreamID == 1)
    #expect(errorCode == .protocolError)
    #expect(peer.events.opened == [1])
    #expect(peer.events.closed == [1])
  }
}

private final class HealthCheckPeer {
  let channel: EmbeddedChannel
  let writes = ProbeWrites()
  let events = StreamEvents()
  let codec: NIOHTTP2Handler
  let input: ChannelHandlerContext

  var frames: [HTTP2Frame] { writes.frames }

  init(configuration: HTTPClient.Configuration? = nil) throws {
    codec = NIOHTTP2Handler(mode: .client)
    channel = EmbeddedChannel(handler: codec)
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
    var configuration = configuration ?? HTTPClient.Configuration()
    if configuration.http2ConnectionDebugInitializer == nil {
      configuration.enableHTTP2HealthChecks()
    }
    let initialize = try #require(configuration.http2ConnectionDebugInitializer)
    try initialize(channel).wait()
    try channel.pipeline.syncOperations.addHandler(writes, position: .after(codec))
    try channel.pipeline.syncOperations.addHandler(events)
    input = try channel.pipeline.syncOperations.context(handler: writes)
  }

  func openStream(_ id: HTTP2StreamID) {
    input.fireUserInboundEventTriggered(NIOHTTP2StreamCreatedEvent(
      streamID: id, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535,
    ))
  }

  func closeStream(_ id: HTTP2StreamID) {
    input.fireUserInboundEventTriggered(StreamClosedEvent(streamID: id, reason: nil))
  }

  func receive(_ payload: HTTP2Frame.FramePayload) {
    input.fireChannelRead(NIOAny(HTTP2Frame(streamID: .rootStream, payload: payload)))
  }

  func advance(_ amount: TimeAmount) {
    channel.embeddedEventLoop.advanceTime(by: amount)
  }

  func ping() -> HTTP2PingData? {
    guard !writes.frames.isEmpty else { return nil }
    let frame = writes.frames.removeFirst()
    #expect(frame.streamID == .rootStream)
    guard case let .ping(id, ack: false) = frame.payload else {
      Issue.record("Expected a PING request")
      return nil
    }
    return id
  }

  func finish() {
    writes.releaseBlockedWrites()
    _ = try? channel.finish(acceptAlreadyClosed: true)
  }
}

private final class ProbeWrites: ChannelOutboundHandler {
  typealias OutboundIn = HTTP2Frame
  enum Completion { case succeeded, failed, blocked }
  var completion = Completion.succeeded
  var frames = [HTTP2Frame]()
  private var blockedPromises = [EventLoopPromise<Void>]()

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    frames.append(unwrapOutboundIn(data))
    switch completion {
    case .succeeded: promise?.succeed(())
    case .failed: promise?.fail(ChannelError.ioOnClosedChannel)
    case .blocked:
      if let promise { blockedPromises.append(promise) }
    }
  }

  func releaseBlockedWrites() {
    for promise in blockedPromises { promise.fail(ChannelError.ioOnClosedChannel) }
    blockedPromises.removeAll()
  }
}

private final class StreamEvents: ChannelInboundHandler {
  typealias InboundIn = HTTP2Frame
  var opened = [HTTP2StreamID]()
  var closed = [HTTP2StreamID]()

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let event = event as? NIOHTTP2StreamCreatedEvent { opened.append(event.streamID) }
    if let event = event as? StreamClosedEvent { closed.append(event.streamID) }
    context.fireUserInboundEventTriggered(event)
  }
}
