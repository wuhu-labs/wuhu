import Logging
import NIOCore
import NIOHTTP2

final class HTTP2HealthCheckHandler: ChannelDuplexHandler {
  typealias InboundIn = HTTP2Frame
  typealias OutboundIn = HTTP2Frame
  typealias OutboundOut = HTTP2Frame

  private var state: HTTP2HealthCheckState
  private var timer: Scheduled<Void>?
  private var scheduledDeadline: NIODeadline?
  private var logger = Logger(label: "FetchAsyncHTTPClient.HTTP2Health")

  init(idleInterval: TimeAmount, acknowledgementTimeout: TimeAmount) {
    let nonce = UInt64.random(in: .min ... .max)
    state = HTTP2HealthCheckState(
      idleInterval: idleInterval,
      acknowledgementTimeout: acknowledgementTimeout,
      initialNonce: nonce,
    )
    logger[metadataKey: "http2-connection"] = .string(String(nonce, radix: 16))
  }

  func handlerAdded(context: ChannelHandlerContext) {
    logger.debug("HTTP/2 health checks enabled")
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    if state.received(frame, now: context.eventLoop.now) {
      logger.info("HTTP/2 health PING acknowledged")
      updateTimer(context: context)
    }
    if case let .goAway(lastStreamID, errorCode, _) = frame.payload {
      logger.notice("HTTP/2 GOAWAY received", metadata: [
        "last-stream-id": .stringConvertible(lastStreamID),
        "error-code": .string(String(describing: errorCode)),
      ])
    }
    context.fireChannelRead(data)
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let event as NIOHTTP2StreamCreatedEvent:
      state.streamOpened(event.streamID, now: context.eventLoop.now)
      logger.debug("HTTP/2 stream opened", metadata: ["stream-id": .stringConvertible(event.streamID)])
    case let event as StreamClosedEvent:
      state.streamClosed(event.streamID)
      logger.debug("HTTP/2 stream closed", metadata: ["stream-id": .stringConvertible(event.streamID)])
    default:
      break
    }
    updateTimer(context: context)
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    stop()
    logger.debug("HTTP/2 connection closed")
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    stop()
  }

  private func updateTimer(context: ChannelHandlerContext) {
    guard scheduledDeadline != state.deadline else { return }
    timer?.cancel()
    timer = nil
    scheduledDeadline = state.deadline
    guard let deadline = scheduledDeadline else { return }
    let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
    timer = context.eventLoop.scheduleTask(deadline: deadline) {
      let (handler, context) = bound.value
      handler.timerFired(context: context)
    }
  }

  private func timerFired(context: ChannelHandlerContext) {
    timer = nil
    scheduledDeadline = nil
    state.timerFired(now: context.eventLoop.now)
    updateTimer(context: context)
    switch state.phase {
    case let .probing(id, _):
      logger.info("HTTP/2 health PING sent")
      let promise = context.eventLoop.makePromise(of: Void.self)
      let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
      promise.futureResult.whenFailure { _ in
        let (handler, context) = bound.value
        guard handler.state.pendingPing == id else { return }
        handler.close(context: context, reason: "HTTP/2 health PING write failed")
      }
      context.writeAndFlush(wrapOutboundOut(HTTP2Frame(streamID: .rootStream, payload: .ping(id, ack: false))), promise: promise)
    case .closed:
      close(context: context, reason: "HTTP/2 health PING acknowledgement timed out")
    case .idle, .waiting:
      break
    }
  }

  private func close(context: ChannelHandlerContext, reason: Logger.Message) {
    logger.warning(reason, metadata: ["active-streams": .stringConvertible(state.streams.count)])
    stop()
    context.close(mode: .all, promise: nil)
  }

  private func stop() {
    state.stop()
    timer?.cancel()
    timer = nil
    scheduledDeadline = nil
  }
}
