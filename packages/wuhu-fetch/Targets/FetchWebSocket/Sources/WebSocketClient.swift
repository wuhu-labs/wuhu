#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import enum PinnedTLS.PinnedTLS

public enum ClientTLS {
  case configuration(TLSConfiguration)
  case pinned(fingerprint: String)
}

public enum WebSocketClientError: Error, Equatable, Sendable {
  case invalidURL(String)
  case refused
}

public struct WebSocketDuplex: Sendable {
  public let inbound: AsyncStream<[UInt8]>
  private let channel: any Channel

  init(inbound: AsyncStream<[UInt8]>, channel: any Channel) {
    self.inbound = inbound
    self.channel = channel
  }

  public func send(_ bytes: [UInt8]) async throws {
    var buffer = channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buffer)
    try await channel.writeAndFlush(frame).get()
  }

  public func close() {
    var buffer = channel.allocator.buffer(capacity: 2)
    buffer.write(webSocketErrorCode: .normalClosure)
    let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: buffer)
    channel.writeAndFlush(frame).whenComplete { _ in
      channel.close(promise: nil)
    }
  }
}

public enum WebSocketClient {
  public static func connect(
    url: URL,
    headers: [(String, String)] = [],
    maxFrameBytes: Int = 1 << 20,
    tls: ClientTLS? = nil,
  ) async throws -> WebSocketDuplex {
    let target = try Target(url: url)
    let sslHandler: (@Sendable () throws -> NIOSSLClientHandler)?
    if target.secure {
      switch tls {
      case .pinned(let fingerprint):
        sslHandler = {
          try PinnedTLS.clientHandler(
            pinnedFingerprint: fingerprint,
            serverHostname: target.serverHostname,
          )
        }
      case .configuration(let configuration):
        let context = try NIOSSLContext(configuration: configuration)
        sslHandler = { try NIOSSLClientHandler(context: context, serverHostname: target.serverHostname) }
      case nil:
        let context = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        sslHandler = { try NIOSSLClientHandler(context: context, serverHostname: target.serverHostname) }
      }
    } else {
      sslHandler = nil
    }
    let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketDuplex>(
      maxFrameSize: maxFrameBytes,
      upgradePipelineHandler: { channel, _ in
        channel.eventLoop.makeCompletedFuture {
          let bridge = InboundBytesBridge()
          try channel.pipeline.syncOperations.addHandler(bridge)
          return WebSocketDuplex(inbound: bridge.inbound, channel: channel)
        }
      },
    )
    var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target.uri)
    head.headers.add(name: "host", value: target.hostHeader)
    for (name, value) in headers {
      head.headers.add(name: name, value: value)
    }
    let configuration = NIOTypedHTTPClientUpgradeConfiguration(
      upgradeRequestHead: head,
      upgraders: [upgrader],
      notUpgradingCompletionHandler: { channel in
        channel.eventLoop.makeFailedFuture(WebSocketClientError.refused)
      },
    )
    let negotiation = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connect(host: target.host, port: target.port) { channel in
        channel.eventLoop.makeCompletedFuture {
          let pipeline = channel.pipeline.syncOperations
          if let sslHandler {
            try pipeline.addHandler(sslHandler())
          }
          return try pipeline.configureUpgradableHTTPClientPipeline(
            configuration: .init(upgradeConfiguration: configuration),
          )
        }
      }
    return try await negotiation.get()
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
      throw WebSocketClientError.invalidURL("unsupported scheme in \(url.absoluteString); use ws://, wss://, http://, or https://")
    }
    guard let host = url.host, !host.isEmpty else {
      throw WebSocketClientError.invalidURL("missing host in \(url.absoluteString)")
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

private final class InboundBytesBridge: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame

  let inbound: AsyncStream<[UInt8]>
  private let continuation: AsyncStream<[UInt8]>.Continuation
  private var accumulated: ByteBuffer?
  private var closeReceived = false

  init() {
    (inbound, continuation) = AsyncStream.makeStream()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .binary, .text:
      accumulated = frame.unmaskedData
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
      let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
      context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
    case .connectionClose:
      if !closeReceived {
        closeReceived = true
        let echo = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: frame.unmaskedData)
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
    guard var buffer = accumulated else { return }
    accumulated = nil
    continuation.yield(buffer.readBytes(length: buffer.readableBytes) ?? [])
  }
}

private extension WebSocketMaskingKey {
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
