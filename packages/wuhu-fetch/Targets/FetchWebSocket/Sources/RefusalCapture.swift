import NIOCore
import NIOHTTP1

final class RefusalCapture: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPClientResponsePart
  private let outcome: DialOutcome
  private let limit: Int
  private var head: HTTPResponseHead?
  private var body: [UInt8] = []

  init(limit: Int, outcome: DialOutcome) {
    self.outcome = outcome
    self.limit = limit
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      if head.status.code != 101 {
        self.head = head
        if limit == 0 { refuse(context: context) }
        return
      }
    case .body(var buffer):
      if head != nil {
        body += buffer.readBytes(length: min(buffer.readableBytes, limit - body.count)) ?? []
        if body.count == limit { refuse(context: context) }
        return
      }
    case .end:
      if head != nil {
        refuse(context: context)
        return
      }
    }
    context.fireChannelRead(data)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if head != nil { refuse(context: context) }
    else { context.fireErrorCaught(error) }
  }

  func channelInactive(context: ChannelHandlerContext) {
    if let error = refusal { outcome.complete(.failure(error)) }
    else { outcome.complete(.failure(WebSocketError.connectionClosed)) }
    context.fireChannelInactive()
  }

  private var refusal: WebSocketError? {
    head.map { .refused(status: Int($0.status.code), headers: $0.headers.fetchHeaders, body: body) }
  }

  private func refuse(context: ChannelHandlerContext) {
    if let error = refusal { outcome.complete(.failure(error)) }
    context.close(promise: nil)
  }
}

final class DialOutcome {
  let promise: EventLoopPromise<WebSocketConnection>
  private var completed = false
  init(on eventLoop: any EventLoop) { promise = eventLoop.makePromise() }
  func complete(_ result: Result<WebSocketConnection, any Error>) {
    guard !completed else { return }
    completed = true
    promise.completeWith(result)
  }
}
