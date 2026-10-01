import Fetch
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Serve
import Synchronization

enum WebSocketNegotiationOutcome: Sendable {
  case http
  case webSocket(WebSocketSession, WebSocket)
}

struct WebSocketUpgradeMisuse: Error {}

// One HTTP request per connection makes this a single-shot stash: the upgrade
// negotiation runs the application handler exactly once, and whichever path the
// connection then takes (upgraded socket or replayed HTTP request) consumes the
// outcome stored here.
final class WebSocketNegotiation: Sendable {
  private struct State {
    var response: Response?
    var session: WebSocketSession?
  }

  private let state = Mutex(State())

  // First write wins: NIO surfaces every refusal as an upgrade error after the
  // application already stashed its real response, and that generic 400 must
  // not clobber it.
  func stash(_ response: Response) {
    state.withLock { state in
      if state.response == nil {
        state.response = response
      }
    }
  }

  func takeResponse() -> Response? {
    state.withLock { state in
      let response = state.response
      state.response = nil
      return response
    }
  }

  func accept(_ session: @escaping WebSocketSession) {
    state.withLock { $0.session = session }
  }

  func takeSession() -> WebSocketSession {
    state.withLock { state in
      guard let session = state.session else {
        preconditionFailure("websocket upgrade completed without an accepted session")
      }
      state.session = nil
      return session
    }
  }
}

extension ServeNIOServer {
  static func webSocketUpgrader(
    options: ServeOptions,
    hooks: ServeNIOHooks,
    context: ServeNIOConnectionContext,
    negotiation: WebSocketNegotiation,
    activity: ConnectionActivity,
    hasTimeoutHandlers: Bool,
    handler: @escaping UpgradingHandler,
  ) -> NIOTypedWebSocketServerUpgrader<WebSocketNegotiationOutcome> {
    NIOTypedWebSocketServerUpgrader(
      maxFrameSize: options.maximumWebSocketFrameBytes,
      shouldUpgrade: { channel, head in
        channel.eventLoop.makeFutureWithTask {
          // A refused upgrade cannot fall back to the HTTP path (NIO never
          // replays the consumed request head), so every refusal must stash
          // the response that the negotiation outcome will write.
          guard head.method == .GET,
                head.headers["content-length"].isEmpty,
                head.headers["transfer-encoding"].isEmpty
          else {
            negotiation.stash(.text("400 Bad Request\n", status: .badRequest))
            return nil
          }
          let request: Request
          do {
            try RequestHeadParser.validateLimits(head, options: options)
            let parsed = try RequestHeadParser.parse(head, options: options)
            request = Request(url: parsed.url, method: parsed.method, headers: parsed.headers)
          } catch let error as ServeError {
            negotiation.stash(.text("\(error.responseStatus.code) \(error.responseStatus.reasonPhrase)\n", status: error.responseStatus))
            return nil
          }
          do {
            switch try await handler(request) {
            case let .response(response):
              negotiation.stash(response)
              return nil
            case let .webSocket(session):
              negotiation.accept(session)
              return HTTPHeaders()
            }
          } catch let error as ServeError {
            negotiation.stash(.text("\(error.responseStatus.code) \(error.responseStatus.reasonPhrase)\n", status: error.responseStatus))
            return nil
          } catch {
            hooks.onHandlerError(context, error)
            negotiation.stash(.text("500 Internal Server Error\n", status: .internalServerError))
            return nil
          }
        }
      },
      upgradePipelineHandler: { channel, _ in
        channel.eventLoop.makeCompletedFuture {
          // The connection is now a long-lived socket. Take the HTTP idle/read
          // timeout handlers out of the pipeline entirely — leaving them dormant
          // would keep them scheduling timers and wrapping every outbound frame
          // write for the life of the socket. markUpgraded guards the brief
          // window until removal completes.
          activity.markUpgraded()
          if hasTimeoutHandlers {
            channel.pipeline.removeHandler(name: idleStateHandlerName, promise: nil)
            channel.pipeline.removeHandler(name: idleTimeoutHandlerName, promise: nil)
          }
          let bridge = WebSocketFrameBridge()
          try channel.pipeline.syncOperations.addHandler(bridge)
          let socket = WebSocket(
            inbound: bridge.inbound,
            send: { message in
              try await channel.writeAndFlush(webSocketFrame(for: message, allocator: channel.allocator)).get()
            },
            close: {
              var buffer = channel.allocator.buffer(capacity: 2)
              buffer.write(webSocketErrorCode: .normalClosure)
              let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
              channel.writeAndFlush(frame).whenComplete { _ in
                channel.close(promise: nil)
              }
            },
            abort: { channel.close(promise: nil) },
          )
          return .webSocket(negotiation.takeSession(), socket)
        }
      },
    )
  }
}

// Catches upgrade refusals decided by NIO's WebSocket upgrader itself (missing
// or malformed Sec-WebSocket-Key/Version) — those never reach the application
// handler, yet still leave the connection without a replayed request.
final class WebSocketRefusalObserver: ChannelInboundHandler {
  typealias InboundIn = Never

  private let negotiation: WebSocketNegotiation

  init(negotiation: WebSocketNegotiation) {
    self.negotiation = negotiation
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    guard error is NIOWebSocketUpgradeError else {
      context.fireErrorCaught(error)
      return
    }
    negotiation.stash(.text("400 Bad Request\n", status: .badRequest))
  }
}

private func webSocketFrame(for message: WebSocketMessage, allocator: ByteBufferAllocator) -> WebSocketFrame {
  switch message {
  case let .binary(bytes):
    var buffer = allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    return WebSocketFrame(fin: true, opcode: .binary, data: buffer)
  case let .text(text):
    var buffer = allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    return WebSocketFrame(fin: true, opcode: .text, data: buffer)
  }
}

final class WebSocketFrameBridge: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame

  let inbound: AsyncStream<WebSocketMessage>
  private let continuation: AsyncStream<WebSocketMessage>.Continuation
  private var accumulated: ByteBuffer?
  private var accumulatedOpcode: WebSocketOpcode?
  private var closeReceived = false

  init() {
    (inbound, continuation) = AsyncStream.makeStream()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .binary, .text:
      accumulated = frame.unmaskedData
      accumulatedOpcode = frame.opcode
      if frame.fin {
        emitAccumulated()
      }
    case .continuation:
      var buffer = frame.unmaskedData
      accumulated?.writeBuffer(&buffer)
      if frame.fin {
        emitAccumulated()
      }
    case .ping:
      let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
      context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
    case .connectionClose:
      if !closeReceived {
        closeReceived = true
        let echo = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
        context.writeAndFlush(wrapOutboundOut(echo), promise: nil)
      }
      continuation.finish()
      context.close(promise: nil)
    default:
      break
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    continuation.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error _: any Error) {
    continuation.finish()
    context.close(promise: nil)
  }

  private func emitAccumulated() {
    guard var buffer = accumulated, let opcode = accumulatedOpcode else { return }
    accumulated = nil
    accumulatedOpcode = nil
    let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
    switch opcode {
    case .text:
      continuation.yield(.text(String(decoding: bytes, as: UTF8.self)))
    default:
      continuation.yield(.binary(bytes))
    }
  }
}
