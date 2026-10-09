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
import NIOSSL
import NIOWebSocket
import enum PinnedTLS.PinnedTLS
import Synchronization

public enum ClientTLS: Sendable {
  case configuration(TLSConfiguration)
  case pinned(fingerprint: String)
}

public enum WebSocketClientError: Error, Equatable, Sendable {
  case invalidURL(String)
  /// The server answered the upgrade with a plain HTTP response: its status
  /// and the start of its body.
  case refused(status: Int, body: [UInt8])
}

public struct WebSocketDuplex: Sendable {
  public let inbound: AsyncStream<[UInt8]>
  private let connection: WebSocketConnection

  init(_ connection: WebSocketConnection) {
    self.connection = connection
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    let pump = Task {
      defer { continuation.finish() }
      do {
        for try await event in connection.inbound {
          if case .message(let message) = event { continuation.yield(message.bytes) }
        }
      } catch {}
    }
    continuation.onTermination = { _ in pump.cancel() }
    inbound = stream
  }

  public func send(_ bytes: [UInt8]) async throws { try await connection.send(.binary(bytes)) }
  public func close() {
    let connection = self.connection
    Task { try? await connection.close() }
  }
}

public enum WebSocketClient {
  public static func connect(
    url: URL,
    headers: [(String, String)] = [],
    maxFrameBytes: Int = 1 << 20,
    tls: ClientTLS? = nil,
  ) async throws -> WebSocketDuplex {
    do {
      return try await WebSocketDuplex(dial(.init(
        url: url,
        limits: .init(
          frameBytes: maxFrameBytes,
          messageBytes: Int.max,
          bufferedReceiveBytes: Int.max,
          outboundMessageBytes: Int.max,
        ), tls: tls,
      ), additionalHeaders: headers))
    } catch let WebSocketError.refused(status, _, body) { throw WebSocketClientError.refused(status: status, body: body) }
    catch WebSocketError.invalidURL(let reason) { throw WebSocketClientError.invalidURL(reason) }
  }

  static func dial(_ request: WebSocketRequest, additionalHeaders: [(String, String)] = []) async throws -> WebSocketConnection {
    try Task.checkCancellation()
    let limits = request.limits
    guard limits.frameBytes > 0, limits.frameBytes <= UInt32.max, limits.messageBytes > 0,
          limits.bufferedReceiveBytes > 0, limits.outboundMessageBytes > 0, limits.refusalBodyBytes >= 0,
          request.connectTimeout > .zero, request.connectTimeout <= .seconds(86400),
          request.closeTimeout >= .zero, request.closeTimeout <= .seconds(86400)
    else {
      throw WebSocketError.invalidConfiguration("invalid limits or timeouts")
    }
    let target = try Target(url: request.url)
    let sslHandler: (@Sendable () throws -> NIOSSLClientHandler)?
    if target.secure {
      switch request.tls {
      case .pinned(let fingerprint):
        sslHandler = { try PinnedTLS.clientHandler(pinnedFingerprint: fingerprint, serverHostname: target.serverHostname) }
      case .configuration(let configuration):
        let context = try tlsContext(configuration)
        sslHandler = { try NIOSSLClientHandler(context: context, serverHostname: target.serverHostname) }
      case nil:
        let context = try tlsContext(TLSConfiguration.makeClientConfiguration())
        sslHandler = { try NIOSSLClientHandler(context: context, serverHostname: target.serverHostname) }
      }
    } else { sslHandler = nil }
    let cancellation = DialCancellation()
    return try await withTaskCancellationHandler {
      do {
        let negotiation = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
          .connectTimeout(request.connectTimeout.nioAmount)
          .connect(host: target.host, port: target.port) { channel in
            channel.eventLoop.makeCompletedFuture {
              cancellation.install(channel)
              let pipeline = channel.pipeline.syncOperations
              if let sslHandler { try pipeline.addHandler(sslHandler()) }
              let outcome = DialOutcome(on: channel.eventLoop)
              let outcomeBound = NIOLoopBound(outcome, eventLoop: channel.eventLoop)
              let refusal = RefusalCapture(limit: request.limits.refusalBodyBytes, outcome: outcome)
              let encoder = HTTPRequestEncoder()
              let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
              var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target.uri)
              head.headers.add(name: "host", value: target.hostHeader)
              for (name, value) in request.headers.values.merging(request.headers.sensitiveValues, uniquingKeysWith: { _, last in last }) {
                head.headers.add(name: name, value: value)
              }
              for (name, value) in additionalHeaders { head.headers.add(name: name, value: value) }
              let offeredProtocols = head.headers["sec-websocket-protocol"].flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
              let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketConnection>(
                maxFrameSize: request.limits.frameBytes, enableAutomaticErrorHandling: false,
                upgradePipelineHandler: { channel, head in
                  channel.eventLoop.makeCompletedFuture {
                    let selected = head.headers["sec-websocket-protocol"]
                    guard selected.isEmpty || (selected.count == 1 && offeredProtocols.contains(selected[0])),
                          !head.headers.contains(name: "sec-websocket-extensions")
                    else {
                      throw WebSocketError.protocolViolation("unoffered subprotocol or unsupported extension")
                    }
                    let bridge = MessageBridge(limits: request.limits)
                    try channel.pipeline.syncOperations.addHandler(bridge)
                    return bridge.connection(channel: channel, headers: head.headers.fetchHeaders, closeTimeout: request.closeTimeout)
                  }
                },
              )
              let upgrade = NIOTypedHTTPClientUpgradeHandler<WebSocketConnection>(
                httpHandlers: [encoder, decoder, refusal],
                upgradeConfiguration: .init(
                  upgradeRequestHead: head,
                  upgraders: [upgrader],
                  notUpgradingCompletionHandler: { channel in channel.eventLoop.makeFailedFuture(WebSocketError.protocolViolation("invalid upgrade")) },
                ),
              )
              try pipeline.addHandlers(encoder, decoder, refusal, upgrade)
              upgrade.upgradeResultFuture.whenComplete { outcomeBound.value.complete($0) }
              let timeout = channel.eventLoop.scheduleTask(in: request.connectTimeout.nioAmount) {
                outcomeBound.value.complete(.failure(WebSocketError.connectTimeout))
                cancellation.timeout()
              }
              outcome.promise.futureResult.whenComplete { _ in timeout.cancel() }
              return outcome.promise.futureResult
            }
          }
        let connection = try await negotiation.get()
        try Task.checkCancellation()
        return connection
      } catch {
        cancellation.abort()
        if Task.isCancelled { throw CancellationError() }
        if cancellation.timedOut { throw WebSocketError.connectTimeout }
        if let error = error as? WebSocketError { throw error }
        if case ChannelError.connectTimeout = error { throw WebSocketError.connectTimeout }
        throw WebSocketError.io(String(describing: error))
      }
    } onCancel: { cancellation.abort() }
  }
}

private final class DialCancellation: Sendable {
  private struct State { var channel: (any Channel)?; var cancelled = false; var timedOut = false }
  private let state = Mutex(State())
  func install(_ channel: any Channel) {
    let cancelled = state.withLock { state in state.channel = channel; return state.cancelled }
    if cancelled { channel.close(promise: nil) }
  }

  var timedOut: Bool { state.withLock { $0.timedOut } }
  func timeout() {
    state.withLock { $0.timedOut = true }
    abort()
  }

  func abort() {
    let channel = state.withLock { state in state.cancelled = true; return state.channel }
    channel?.close(promise: nil)
  }
}

extension Duration {
  var nioAmount: TimeAmount {
    let parts = components
    return .nanoseconds(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
  }
}

extension HTTPHeaders {
  var fetchHeaders: Headers {
    var result = Headers()
    for (name, value) in self { result.append(.init(name: .init(name)!, value: value)) }
    return result
  }
}

private struct Target {
  let host: String
  let port: Int
  let hostHeader: String
  let uri: String
  let secure: Bool

  // SNI forbids IP literals; those handshake without a server hostname.
  var serverHostname: String? {
    if (try? SocketAddress(ipAddress: self.host, port: self.port)) != nil {
      return nil
    }
    return self.host
  }

  init(url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), ["ws", "http", "wss", "https"].contains(scheme) else {
      throw WebSocketError.invalidURL("unsupported scheme in \(url.absoluteString); use ws://, wss://, http://, or https://")
    }
    guard let host = url.host, !host.isEmpty else {
      throw WebSocketError.invalidURL("missing host in \(url.absoluteString)")
    }
    self.host = host
    secure = scheme == "wss" || scheme == "https"
    port = url.port ?? (secure ? 443 : 80)
    hostHeader = url.port.map { "\(host):\($0)" } ?? host
    // The request target must carry the raw bytes: decoding %2F or %20 here
    // would change route semantics or break the request line.
    let rawPath = url.path(percentEncoded: true)
    let path = rawPath.isEmpty ? "/" : rawPath
    uri = url.query(percentEncoded: true).map { "\(path)?\($0)" } ?? path
  }
}

extension WebSocketMaskingKey {
  static func random() -> WebSocketMaskingKey {
    var generator = SystemRandomNumberGenerator()
    let value = generator.next() as UInt64
    return WebSocketMaskingKey([
      UInt8(truncatingIfNeeded: value),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 24),
    ])!
  }
}

private func tlsContext(_ configuration: TLSConfiguration) throws -> NIOSSLContext {
  do { return try NIOSSLContext(configuration: configuration) }
  catch { throw WebSocketError.tls(String(describing: error)) }
}
