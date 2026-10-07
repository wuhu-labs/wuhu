import Fetch
import NIOCore
import NIOWebSocket
import Synchronization

final class MessageBridge: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  private let limits: WebSocketLimits
  private let continuation: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation
  private let inbound: WebSocketInbound
  private let budget = ReceiveBudget()
  private var accumulated: [UInt8] = []
  private var opcode: WebSocketOpcode?
  private var closed = false
  private var closing = false

  init(limits: WebSocketLimits) {
    self.limits = limits
    let (stream, continuation) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    self.continuation = continuation
    let budget = self.budget
    inbound = WebSocketInbound(stream, consumed: { event in
      if case .message(let message) = event { budget.bytes.withLock { $0 -= max(1, message.byteCount) } }
    })
  }

  func connection(channel: any Channel, headers: Headers, closeTimeout: Duration) -> WebSocketConnection {
    let bridge = NIOLoopBound(self, eventLoop: channel.eventLoop)
    continuation.onTermination = { termination in
      if case .cancelled = termination { channel.close(promise: nil) }
    }
    return WebSocketConnection(responseHeaders: headers, inbound: inbound, send: { message in
      do {
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          try await channel.eventLoop.submit {
            guard !bridge.value.closed && !bridge.value.closing else { throw WebSocketError.connectionClosed }
            guard message.byteCount <= bridge.value.limits.outboundMessageBytes else { throw WebSocketError.limitExceeded(.outboundMessage) }
            let bytes = message.bytes
            let opcode: WebSocketOpcode = if case .text = message { .text } else { .binary }
            let frame = WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: channel.allocator.buffer(bytes: bytes))
            return channel.writeAndFlush(frame)
          }.flatMap { $0 }.get()
        } onCancel: { channel.close(promise: nil) }
      } catch {
        if Task.isCancelled { throw CancellationError() }
        if let error = error as? WebSocketError { throw error }
        throw WebSocketError.io(String(describing: error))
      }
    }, close: { close in
      guard validCloseCode(close.code), close.reason.utf8.count <= 123 else { throw WebSocketError.protocolViolation("invalid close") }
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await channel.eventLoop.submit {
          if bridge.value.closed || bridge.value.closing { return }
          bridge.value.closing = true
          var buffer = channel.allocator.buffer(capacity: 125)
          buffer.writeInteger(close.code)
          buffer.writeString(close.reason)
          channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: buffer), promise: nil)
          let timeout = channel.eventLoop.scheduleTask(in: closeTimeout.nioAmount) { channel.close(promise: nil) }
          channel.closeFuture.whenComplete { _ in timeout.cancel() }
        }.get()
        try await channel.closeFuture.get()
        try Task.checkCancellation()
      } onCancel: { channel.close(promise: nil) }
    }, abort: {
      channel.eventLoop.execute {
        bridge.value.fail(WebSocketError.cancelled)
        channel.close(promise: nil)
      }
    })
  }

  func handlerAdded(context: ChannelHandlerContext) {
    if !context.channel.isActive { fail(WebSocketError.connectionClosed) }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !closed else { return }
    let frame = unwrapInboundIn(data)
    do {
      guard !frame.rsv1 && !frame.rsv2 && !frame.rsv3 else { throw WebSocketError.protocolViolation("unnegotiated extension") }
      guard frame.maskKey == nil else { throw WebSocketError.protocolViolation("masked server frame") }
      guard frame.data.readableBytes <= limits.frameBytes else { throw WebSocketError.limitExceeded(.frame) }
      var buffer = frame.unmaskedData
      let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
      switch frame.opcode {
      case .binary, .text:
        guard opcode == nil else { throw WebSocketError.protocolViolation("overlapping fragmented messages") }
        opcode = frame.opcode
        try append(bytes)
        if frame.fin { try emit() }
      case .continuation:
        guard opcode != nil else { throw WebSocketError.protocolViolation("unexpected continuation") }
        try append(bytes)
        if frame.fin { try emit() }
      case .ping, .pong, .connectionClose:
        guard frame.fin && bytes.count <= 125 else { throw WebSocketError.protocolViolation("invalid control frame") }
        if frame.opcode == .ping {
          context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)), promise: nil)
        } else if frame.opcode == .connectionClose {
          guard bytes.count != 1 else { throw WebSocketError.protocolViolation("invalid close payload") }
          let code = bytes.isEmpty ? 1005 : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
          guard bytes.isEmpty || validCloseCode(code), let reason = String(validating: bytes.dropFirst(2), as: UTF8.self) else {
            throw WebSocketError.protocolViolation("invalid close code or UTF-8")
          }
          closed = true
          continuation.yield(.closed(.init(code: code, reason: reason)))
          continuation.finish()
          if !closing {
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: frame.unmaskedData)), promise: nil)
          }
          context.close(promise: nil)
        }
      default: throw WebSocketError.protocolViolation("unknown opcode")
      }
    } catch {
      fail(error)
      context.close(promise: nil)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    fail(WebSocketError.connectionClosed)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if let error = error as? NIOWebSocketError, error == .invalidFrameLength {
      fail(WebSocketError.limitExceeded(.frame))
    } else if error is NIOWebSocketError {
      fail(WebSocketError.protocolViolation(String(describing: error)))
    } else { fail(WebSocketError.io(String(describing: error))) }
    context.close(promise: nil)
  }

  private func append(_ bytes: [UInt8]) throws {
    guard bytes.count <= limits.messageBytes - accumulated.count else { throw WebSocketError.limitExceeded(.message) }
    accumulated += bytes
  }

  private func emit() throws {
    let message: WebSocketMessage
    if opcode == .text {
      guard let text = String(validating: accumulated, as: UTF8.self) else { throw WebSocketError.protocolViolation("invalid text UTF-8") }
      message = .text(text)
    } else { message = .binary(accumulated) }
    let cost = max(1, accumulated.count)
    guard budget.bytes.withLock({ used in
      guard cost <= limits.bufferedReceiveBytes - used else { return false }
      used += cost
      return true
    }) else { throw WebSocketError.limitExceeded(.bufferedReceive) }
    accumulated = []
    opcode = nil
    continuation.yield(.message(message))
  }

  private func fail(_ error: any Error) {
    guard !closed else { return }
    closed = true
    accumulated = []
    continuation.finish(throwing: error)
  }
}

private final class ReceiveBudget: Sendable { let bytes = Mutex(0) }

private func validCloseCode(_ code: UInt16) -> Bool {
  (1000 ... 1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000 ... 4999).contains(code)
}
