#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import HTTPTypes
import Synchronization

public enum WebSocketMessage: Sendable, Equatable {
  case text(String)
  case binary([UInt8])

  var byteCount: Int {
    switch self {
    case .text(let text): text.utf8.count
    case .binary(let bytes): bytes.count
    }
  }

  var bytes: [UInt8] {
    switch self {
    case .text(let text): Array(text.utf8)
    case .binary(let bytes): bytes
    }
  }
}

public struct WebSocketClose: Sendable, Equatable {
  public var code: UInt16
  public var reason: String

  public init(code: UInt16 = 1000, reason: String = "") {
    self.code = code
    self.reason = reason
  }
}

public enum WebSocketEvent: Sendable, Equatable {
  case message(WebSocketMessage)
  case closed(WebSocketClose)
}

public struct WebSocketLimits: Sendable, Equatable {
  public var frameBytes: Int
  public var messageBytes: Int
  public var bufferedReceiveBytes: Int
  public var outboundMessageBytes: Int
  public var refusalBodyBytes: Int

  public init(
    frameBytes: Int = 1 << 20,
    messageBytes: Int = 1 << 20,
    bufferedReceiveBytes: Int = 1 << 20,
    outboundMessageBytes: Int = 1 << 20,
    refusalBodyBytes: Int = 8192,
  ) {
    precondition(frameBytes > 0 && messageBytes > 0 && bufferedReceiveBytes > 0 && outboundMessageBytes > 0 && refusalBodyBytes >= 0)
    self.frameBytes = frameBytes
    self.messageBytes = messageBytes
    self.bufferedReceiveBytes = bufferedReceiveBytes
    self.outboundMessageBytes = outboundMessageBytes
    self.refusalBodyBytes = refusalBodyBytes
  }
}

public struct WebSocketRequest: Sendable {
  public var url: URL
  public var headers: RequestHeaders
  public var limits: WebSocketLimits
  public var tls: ClientTLS?
  public var connectTimeout: Duration
  public var closeTimeout: Duration

  public init(
    url: URL,
    headers: RequestHeaders = .init(),
    limits: WebSocketLimits = .init(),
    tls: ClientTLS? = nil,
    connectTimeout: Duration = .seconds(30),
    closeTimeout: Duration = .seconds(2),
  ) {
    self.url = url
    self.headers = headers
    self.limits = limits
    self.tls = tls
    self.connectTimeout = connectTimeout
    self.closeTimeout = closeTimeout
  }
}

public enum WebSocketError: Error, Sendable, Equatable {
  case unimplemented
  case invalidURL(String)
  case invalidConfiguration(String)
  case tls(String)
  case refused(status: Int, headers: Headers, body: [UInt8])
  case protocolViolation(String)
  case limitExceeded(Limit)
  case connectionClosed
  case connectTimeout
  case io(String)
  case cancelled
  case multipleConsumers

  public enum Limit: Sendable, Equatable {
    case frame, message, bufferedReceive, outboundMessage
  }
}

public struct WebSocketInbound: AsyncSequence, Sendable {
  public typealias Element = WebSocketEvent
  public struct AsyncIterator: AsyncIteratorProtocol {
    var iterator: AsyncThrowingStream<WebSocketEvent, any Error>.Iterator
    let consumed: @Sendable (WebSocketEvent) -> Void
    let allowed: Bool

    public mutating func next() async throws -> WebSocketEvent? {
      guard allowed else { throw WebSocketError.multipleConsumers }
      guard let event = try await iterator.next() else { return nil }
      consumed(event)
      return event
    }
  }

  private let stream: AsyncThrowingStream<WebSocketEvent, any Error>
  private let consumed: @Sendable (WebSocketEvent) -> Void
  private let claim = ReceiveClaim()

  public init(_ stream: AsyncThrowingStream<WebSocketEvent, any Error>) {
    self.init(stream, consumed: { _ in })
  }

  init(_ stream: AsyncThrowingStream<WebSocketEvent, any Error>, consumed: @escaping @Sendable (WebSocketEvent) -> Void) {
    self.stream = stream
    self.consumed = consumed
  }

  public func makeAsyncIterator() -> AsyncIterator {
    let allowed = claim.claimed.withLock { claimed in
      defer { claimed = true }
      return !claimed
    }
    return AsyncIterator(iterator: stream.makeAsyncIterator(), consumed: consumed, allowed: allowed)
  }
}

public struct WebSocketConnection: Sendable {
  public let responseHeaders: Headers
  public let inbound: WebSocketInbound
  private let sender: @Sendable (WebSocketMessage) async throws -> Void
  private let closer: @Sendable (WebSocketClose) async throws -> Void
  private let aborter: @Sendable () -> Void

  public init(
    responseHeaders: Headers = .init(),
    inbound: WebSocketInbound,
    send: @escaping @Sendable (WebSocketMessage) async throws -> Void,
    close: @escaping @Sendable (WebSocketClose) async throws -> Void,
    abort: @escaping @Sendable () -> Void,
  ) {
    self.responseHeaders = responseHeaders
    self.inbound = inbound
    sender = send
    closer = close
    aborter = abort
  }

  public func send(_ message: WebSocketMessage) async throws { try await sender(message) }
  public func close(_ close: WebSocketClose = .init()) async throws { try await closer(close) }
  public func abort() { aborter() }
}

public struct WebSocketConnector: Sendable, TestDependencyKey {
  public var connect: @Sendable (WebSocketRequest) async throws -> WebSocketConnection

  public init(connect: @escaping @Sendable (WebSocketRequest) async throws -> WebSocketConnection) {
    self.connect = connect
  }

  public static let testValue: Self = Self { _ in throw WebSocketError.unimplemented }
  public static let live: Self = Self { try await WebSocketClient.dial($0) }
}

private final class ReceiveClaim: Sendable {
  let claimed = Mutex(false)
}
