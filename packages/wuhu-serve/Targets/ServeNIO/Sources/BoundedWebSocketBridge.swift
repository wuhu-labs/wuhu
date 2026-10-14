import Fetch
import FetchTunnel
import NIOCore
import NIOWebSocket
import Synchronization

final class BoundedWebSocketBridge: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  let limits: BoundedWebSocketLimits
  let continuation: AsyncThrowingStream<Bytes, any Error>.Continuation
  private let receiver: BoundedReceiver
  private let budget = BoundedBudget()
  var accumulated: [UInt8] = []
  var fragmented = false
  var closed = false
  private var pendingControlWrites = 0

  init(limits: BoundedWebSocketLimits) {
    self.limits = limits
    let (stream, continuation) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    self.continuation = continuation
    receiver = BoundedReceiver(stream)
  }

  func transport(channel: any Channel, maximumFrameBytes: Int = Int.max) -> TunnelTransport {
    let bridge = NIOLoopBound(self, eventLoop: channel.eventLoop)
    let budget = self.budget
    let receiver = self.receiver
    let maximumMessageBytes = min(limits.messageBytes, maximumFrameBytes)
    continuation.onTermination = { _ in channel.close(promise: nil) }
    return TunnelTransport(maxMessageBytes: maximumMessageBytes, receive: {
      guard let bytes = try await receiver.next() else { return nil }
      budget.bytes.withLock { $0 -= BoundedBudget.cost(bytes.count) }
      return bytes
    }, send: { bytes in
      guard bytes.count <= maximumMessageBytes else { throw TunnelError.webSocketLimitExceeded }
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await channel.eventLoop.submit {
          guard !bridge.value.closed else { throw TunnelError.connectionClosed }
          return channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(bytes: bytes)))
        }.flatMap { $0 }.get()
      } onCancel: { channel.close(promise: nil) }
    }, abort: { channel.close(promise: nil) })
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !closed else { return }
    let frame = unwrapInboundIn(data)
    do {
      guard !frame.rsv1 && !frame.rsv2 && !frame.rsv3, frame.maskKey != nil else { throw TunnelError.protocolViolation }
      guard frame.data.readableBytes <= limits.messageBytes else { throw TunnelError.webSocketLimitExceeded }
      switch frame.opcode {
      case .binary:
        guard !fragmented else { throw TunnelError.protocolViolation }
        fragmented = true
        try append(frame)
        if frame.fin { try emit() }
      case .continuation:
        guard fragmented else { throw TunnelError.protocolViolation }
        try append(frame)
        if frame.fin { try emit() }
      case .ping, .pong, .connectionClose:
        guard frame.fin, frame.data.readableBytes <= 125 else { throw TunnelError.protocolViolation }
        if frame.opcode == .ping {
          try writePong(frame.unmaskedData, channel: context.channel)
        } else if frame.opcode == .connectionClose {
          try validateClose(frame.unmaskedData)
          continuation.finish(throwing: TunnelError.connectionClosed)
          closed = true
          context.close(promise: nil)
        }
      default: throw TunnelError.protocolViolation
      }
    } catch {
      fail(error)
      context.close(promise: nil)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    fail(TunnelError.connectionClosed)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if let error = error as? NIOWebSocketError, error == .invalidFrameLength {
      fail(TunnelError.webSocketLimitExceeded)
    } else { fail(TunnelError.protocolViolation) }
    context.close(promise: nil)
  }

  private func writePong(_ data: ByteBuffer, channel: any Channel) throws {
    guard channel.isWritable, pendingControlWrites < 16 else { throw TunnelError.capacityExceeded }
    pendingControlWrites += 1
    let bridge = NIOLoopBound(self, eventLoop: channel.eventLoop)
    let promise = channel.eventLoop.makePromise(of: Void.self)
    promise.futureResult.whenComplete { result in
      bridge.value.pendingControlWrites -= 1
      if case .failure = result, !bridge.value.closed {
        bridge.value.fail(TunnelError.connectionClosed)
        channel.close(promise: nil)
      }
    }
    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .pong, data: data), promise: promise)
  }

  private func validateClose(_ buffer: ByteBuffer) throws {
    let bytes = Array(buffer.readableBytesView)
    guard bytes.isEmpty || bytes.count >= 2 else { throw TunnelError.protocolViolation }
    if bytes.isEmpty { return }
    let code = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    guard ((1000 ... 1014).contains(code) && ![1004, 1005, 1006].contains(code)) || (3000 ... 4999).contains(code),
          String(validating: bytes.dropFirst(2), as: UTF8.self) != nil
    else { throw TunnelError.protocolViolation }
  }

  private func append(_ frame: WebSocketFrame) throws {
    var data = frame.unmaskedData
    guard data.readableBytes <= limits.messageBytes - accumulated.count else { throw TunnelError.webSocketLimitExceeded }
    accumulated += data.readBytes(length: data.readableBytes) ?? []
  }

  private func emit() throws {
    let cost = BoundedBudget.cost(accumulated.count)
    guard budget.bytes.withLock({ used in
      guard cost <= limits.bufferedReceiveBytes - used else { return false }
      used += cost
      return true
    }) else { throw TunnelError.webSocketLimitExceeded }
    continuation.yield(Bytes(accumulated))
    accumulated = []
    fragmented = false
  }

  private func fail(_ error: any Error) {
    guard !closed else { return }
    closed = true
    accumulated = []
    continuation.finish(throwing: error)
  }
}

private actor BoundedReceiver {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  var advancing = false
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    guard !advancing else { throw TunnelError.protocolViolation }
    advancing = true
    defer { advancing = false }
    var iterator = self.iterator
    let bytes = try await iterator.next(isolation: self)
    self.iterator = iterator
    return bytes
  }
}

private final class BoundedBudget: Sendable {
  let bytes = Mutex(0)
  static func cost(_ count: Int) -> Int { max(1024, count) }
}
