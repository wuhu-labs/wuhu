#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

public enum PinnedFetchError: Error, Sendable {
  case unsupportedURL(String)
  case timedOut
  case connectionClosedBeforeResponseEnded
}

extension PinnedTLS {
  // AsyncHTTPClient builds its TLS handlers from a bare TLSConfiguration and
  // offers no custom-verification hook, so pinned HTTP traffic dials its own
  // one-connection-per-request HTTP/1.1 channel here.
  public static func fetch(
    _ request: Fetch.Request,
    pinnedFingerprint: String,
    timeout: TimeAmount? = .seconds(30),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
  ) async throws -> Fetch.Response {
    guard request.url.scheme?.lowercased() == "https", let host = request.url.host, !host.isEmpty else {
      throw PinnedFetchError.unsupportedURL(request.url.absoluteString)
    }
    let port = request.url.port ?? 443
    let serverHostname = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil
    // Happy-eyeballs runs the channel initializer once per address attempt,
    // and a losing attempt's teardown fires handlerRemoved: outcome state must
    // be per channel or the loser poisons the winning dial.
    let attempts = Mutex<[ObjectIdentifier: DialAttempt]>([:])
    let relay = CancellationRelay()
    return try await withTaskCancellationHandler {
      let channel = try await ClientBootstrap(group: eventLoopGroup)
        .connect(host: host, port: port) { channel in
          channel.eventLoop.makeCompletedFuture {
            let headPromise = channel.eventLoop.makePromise(of: HTTPResponseHead.self)
            let (bodyStream, bodyContinuation) = AsyncThrowingStream<Bytes, any Error>.makeStream()
            let pipeline = channel.pipeline.syncOperations
            try pipeline.addHandler(
              clientHandler(pinnedFingerprint: pinnedFingerprint, serverHostname: serverHostname),
            )
            try pipeline.addHTTPClientHandlers()
            try pipeline.addHandler(ResponseBridge(head: headPromise, body: bodyContinuation))
            attempts.withLock {
              $0[ObjectIdentifier(channel)] = DialAttempt(
                head: headPromise.futureResult,
                body: bodyStream,
                bodyContinuation: bodyContinuation,
              )
            }
            return channel
          }
        }
      let attempt = attempts.withLock { $0[ObjectIdentifier(channel)] }
      guard let attempt else {
        channel.close(promise: nil)
        throw PinnedFetchError.connectionClosedBeforeResponseEnded
      }
      // From here the bridge owns completion: every failure path closes the
      // channel and the bridge resolves the head promise and body stream.
      relay.register(channel)
      attempt.bodyContinuation.onTermination = { _ in channel.close(promise: nil) }
      if let timeout {
        // The deadline covers connect + response head only; body streaming
        // (SSE, long downloads) is bounded by the consumer, not the timer.
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
          channel.pipeline.fireErrorCaught(PinnedFetchError.timedOut)
          channel.close(promise: nil)
        }
        attempt.head.whenComplete { _ in deadline.cancel() }
      }
      do {
        do {
          try await channel.writeAndFlush(HTTPClientRequestPart.head(requestHead(for: request, host: host))).get()
          if let body = request.body {
            for try await chunk in body.asyncBytes() where !chunk.isEmpty {
              try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: chunk)))).get()
            }
          }
          try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        } catch let error as ChannelError where error == .ioOnClosedChannel || error == .alreadyClosed {
          // A server may answer and close before the request finishes writing
          // (legal early response). A closed channel guarantees the bridge
          // resolves — with the response it drained or with a failure — so the
          // outcome is the bridge's, not the failed write's.
        }
        let head = try await attempt.head.get()
        return Response(
          status: Status(code: Int(head.status.code), reasonPhrase: head.status.reasonPhrase),
          headers: fields(from: head.headers),
          body: .stream(
            length: head.headers.first(name: "content-length").flatMap(Int64.init),
            contentType: head.headers.first(name: "content-type"),
            attempt.body,
          ),
        )
      } catch {
        channel.close(promise: nil)
        throw Task.isCancelled ? CancellationError() : error
      }
    } onCancel: {
      relay.cancel()
    }
  }
}

private struct DialAttempt: Sendable {
  let head: EventLoopFuture<HTTPResponseHead>
  let body: AsyncThrowingStream<Bytes, any Error>
  let bodyContinuation: AsyncThrowingStream<Bytes, any Error>.Continuation
}

private final class CancellationRelay: Sendable {
  private struct State {
    var channel: (any Channel)?
    var cancelled = false
  }

  private let state = Mutex(State())

  func register(_ channel: any Channel) {
    let cancelled = state.withLock { state in
      state.channel = channel
      return state.cancelled
    }
    if cancelled {
      channel.close(promise: nil)
    }
  }

  func cancel() {
    let channel = state.withLock { state in
      state.cancelled = true
      return state.channel
    }
    channel?.close(promise: nil)
  }
}

private func requestHead(for request: Fetch.Request, host: String) -> HTTPRequestHead {
  // The request target must carry the raw bytes: decoding %2F or %20 here
  // would change route semantics or break the request line.
  let rawPath = request.url.path(percentEncoded: true)
  let path = rawPath.isEmpty ? "/" : rawPath
  let uri = request.url.query(percentEncoded: true).map { "\(path)?\($0)" } ?? path
  var head = HTTPRequestHead(version: .http1_1, method: .init(rawValue: request.method.rawValue), uri: uri)
  head.headers.add(name: "host", value: request.url.port.map { "\(host):\($0)" } ?? host)
  for field in request.headers.fields {
    head.headers.add(name: field.name.rawName, value: field.value)
  }
  for (name, value) in request.headers.sensitiveValues {
    head.headers.add(name: name, value: value)
  }
  if let body = request.body {
    if head.headers["content-type"].isEmpty, let contentType = body.contentType {
      head.headers.add(name: "content-type", value: contentType)
    }
    if let length = body.contentLength {
      if head.headers["content-length"].isEmpty {
        head.headers.add(name: "content-length", value: String(length))
      }
    } else {
      head.headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
    }
  } else {
    switch head.method {
    case .GET, .HEAD, .DELETE, .CONNECT, .TRACE:
      break
    default:
      // A bodiless request whose method admits a body still needs explicit
      // framing — servers may 400 an unframed POST before routing (AHC parity).
      head.headers.replaceOrAdd(name: "content-length", value: "0")
    }
  }
  head.headers.replaceOrAdd(name: "connection", value: "close")
  return head
}

private func fields(from headers: HTTPHeaders) -> Headers {
  var fields = Headers()
  for (name, value) in headers {
    if let fieldName = HTTPField.Name(name) {
      fields.append(HTTPField(name: fieldName, value: value))
    }
  }
  return fields
}

private final class ResponseBridge: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart

  private enum State {
    case awaitingHead
    case streaming
    case finished
  }

  private let head: EventLoopPromise<HTTPResponseHead>
  private let body: AsyncThrowingStream<Bytes, any Error>.Continuation
  private var state: State = .awaitingHead

  init(head: EventLoopPromise<HTTPResponseHead>, body: AsyncThrowingStream<Bytes, any Error>.Continuation) {
    self.head = head
    self.body = body
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let responseHead):
      state = .streaming
      head.succeed(responseHead)
    case .body(let buffer):
      body.yield(Data(buffer.readableBytesView))
    case .end:
      state = .finished
      body.finish()
      context.close(promise: nil)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    fail(error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    fail(PinnedFetchError.connectionClosedBeforeResponseEnded)
    context.fireChannelInactive()
  }

  func handlerRemoved(context _: ChannelHandlerContext) {
    fail(PinnedFetchError.connectionClosedBeforeResponseEnded)
  }

  private func fail(_ error: any Error) {
    switch state {
    case .awaitingHead:
      head.fail(error)
      body.finish(throwing: error)
    case .streaming:
      body.finish(throwing: error)
    case .finished:
      return
    }
    state = .finished
  }
}
