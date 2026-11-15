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
  private let budget: ReceiveBudget
  private var accumulated: [UInt8] = []
  private var opcode: WebSocketOpcode?
  private var termination: WebSocketError?
  private var closed: Bool { termination != nil }
  private var closing = false
  private var pendingControlWrites = 0
  private var sending: EventLoopFuture<Void>?
  static let fragmentBytes = 64 << 10

  init(limits: WebSocketLimits) {
    self.limits = limits
    budget = ReceiveBudget(minimumMessageCost: limits.bufferedReceiveBytes == Int.max ? 1 : 1024)
    let (stream, continuation) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    self.continuation = continuation
    let budget = self.budget
    inbound = WebSocketInbound(stream, consumed: { event in
      if case .message(let message) = event { budget.bytes.withLock { $0 -= budget.cost(message.byteCount) } }
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
            let buffer = channel.allocator.buffer(bytes: message.bytes)
            let opcode: WebSocketOpcode = if case .text = message { .text } else { .binary }
            return try bridge.value.afterEarlierSends(on: channel.eventLoop) {
              if let termination = bridge.value.termination { return channel.eventLoop.makeFailedFuture(termination) }
              let written = writeFragments(of: buffer, opcode: opcode, to: channel)
              written.whenFailure { bridge.value.abort(afterFailedWrite: $0, channel: channel) }
              return written
            }.flatMapErrorThrowing { throw bridge.value.termination ?? $0 }
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
          try bridge.value.afterEarlierSends(on: channel.eventLoop) { () throws(WebSocketError) in
            try bridge.value.writeControl(.connectionClose, data: buffer, channel: channel)
          }
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
    do throws(WebSocketError) {
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
          try writeControl(.pong, data: frame.unmaskedData, channel: context.channel)
        } else if frame.opcode == .connectionClose {
          guard bytes.count != 1 else { throw WebSocketError.protocolViolation("invalid close payload") }
          let code = bytes.isEmpty ? 1005 : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
          guard bytes.isEmpty || validCloseCode(code), let reason = String(validating: bytes.dropFirst(2), as: UTF8.self) else {
            throw WebSocketError.protocolViolation("invalid close code or UTF-8")
          }
          termination = .connectionClosed
          continuation.yield(.closed(.init(code: code, reason: reason)))
          continuation.finish()
          if closing {
            context.close(promise: nil)
          } else {
            let channel = context.channel
            let reply = frame.unmaskedData
            try afterEarlierSends(on: channel.eventLoop) { () throws(WebSocketError) in
              try self.writeControl(.connectionClose, data: reply, channel: channel)
            }.whenComplete { _ in channel.close(promise: nil) }
          }
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

  /// Sends serialize here, so data frames of two messages never interleave; a pong skips this queue and goes out between fragments.
  @discardableResult
  private func afterEarlierSends(
    on loop: any EventLoop, _ write: @escaping () throws(WebSocketError) -> EventLoopFuture<Void>,
  ) throws(WebSocketError) -> EventLoopFuture<Void> {
    let written: EventLoopFuture<Void>
    if let sending {
      let promise = loop.makePromise(of: Void.self)
      sending.assumeIsolated().whenComplete { _ in
        do throws(WebSocketError) { try promise.completeWith(write()) } catch { promise.fail(error) }
      }
      written = promise.futureResult
    } else { written = try write() }
    sending = written
    written.assumeIsolated().whenComplete { _ in if self.sending === written { self.sending = nil } }
    return written
  }

  @discardableResult
  private func writeControl(_ opcode: WebSocketOpcode, data: ByteBuffer, channel: any Channel) throws(WebSocketError) -> EventLoopFuture<Void> {
    if limits.messageBytes == Int.max, limits.bufferedReceiveBytes == Int.max, limits.outboundMessageBytes == Int.max {
      return channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: data))
    }
    guard pendingControlWrites < 16 else {
      let error = WebSocketError.limitExceeded(.outboundMessage)
      fail(error)
      channel.close(promise: nil)
      throw error
    }
    pendingControlWrites += 1
    let bridge = NIOLoopBound(self, eventLoop: channel.eventLoop)
    let promise = channel.eventLoop.makePromise(of: Void.self)
    promise.futureResult.whenComplete { result in
      bridge.value.pendingControlWrites -= 1
      if case .failure(let error) = result { bridge.value.abort(afterFailedWrite: error, channel: channel) }
    }
    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: data), promise: promise)
    return promise.futureResult
  }

  private func abort(afterFailedWrite error: any Error, channel: any Channel) {
    guard !closed else { return }
    fail(error as? WebSocketError ?? .io(String(describing: error)))
    channel.close(promise: nil)
  }

  private func append(_ bytes: [UInt8]) throws(WebSocketError) {
    guard bytes.count <= limits.messageBytes - accumulated.count else { throw WebSocketError.limitExceeded(.message) }
    accumulated += bytes
  }

  private func emit() throws(WebSocketError) {
    let message: WebSocketMessage
    if opcode == .text {
      guard let text = String(validating: accumulated, as: UTF8.self) else { throw WebSocketError.protocolViolation("invalid text UTF-8") }
      message = .text(text)
    } else { message = .binary(accumulated) }
    let cost = budget.cost(accumulated.count)
    guard budget.bytes.withLock({ used in
      guard cost <= limits.bufferedReceiveBytes - used else { return false }
      used += cost
      return true
    }) else { throw WebSocketError.limitExceeded(.bufferedReceive) }
    accumulated = []
    opcode = nil
    continuation.yield(.message(message))
  }

  private func fail(_ error: WebSocketError) {
    guard !closed else { return }
    termination = error
    accumulated = []
    continuation.finish(throwing: error)
  }
}

private final class ReceiveBudget: Sendable {
  let bytes = Mutex(0)
  let minimumMessageCost: Int
  init(minimumMessageCost: Int) { self.minimumMessageCost = minimumMessageCost }
  func cost(_ count: Int) -> Int { max(minimumMessageCost, count) }
}

/// Each fragment is written only once the previous one is, so a pong written meanwhile waits behind at most one fragment.
private func writeFragments(of message: ByteBuffer, opcode: WebSocketOpcode, to channel: any Channel) -> EventLoopFuture<Void> {
  var buffer = message
  let fragment = buffer.readSlice(length: min(buffer.readableBytes, MessageBridge.fragmentBytes))!
  let rest = buffer
  let written = channel.writeAndFlush(WebSocketFrame(fin: rest.readableBytes == 0, opcode: opcode, maskKey: .random(), data: fragment))
  return rest.readableBytes == 0 ? written : written.flatMap { writeFragments(of: rest, opcode: .continuation, to: channel) }
}

private func validCloseCode(_ code: UInt16) -> Bool {
  (1000 ... 1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000 ... 4999).contains(code)
}
