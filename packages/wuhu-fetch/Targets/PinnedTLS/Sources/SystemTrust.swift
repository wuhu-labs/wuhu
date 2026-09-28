#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import NIOCore
import NIOPosix
import NIOSSL
import enum NIOTLS.TLSUserEvent
import Synchronization

public enum SystemTrustError: Error, Equatable, Sendable {
  case connectionClosedBeforeHandshake
  case handshakeTimedOut
}

public enum SystemTrust {
  public static func validate(
    host: String,
    port: Int,
    anchors: TrustAnchors,
    timeout: TimeAmount? = .seconds(10),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
  ) async throws {
    let context = try NIOSSLContext(configuration: anchors.clientConfiguration())
    let serverHostname = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil
    // Happy-eyeballs runs the channel initializer once per address attempt,
    // and a losing attempt's teardown fails its observer: the handshake
    // outcome must be per channel or the loser poisons the winning dial.
    let attempts = Mutex<[ObjectIdentifier: EventLoopFuture<Void>]>([:])
    let channel = try await ClientBootstrap(group: eventLoopGroup)
      .connect(host: host, port: port) { channel in
        channel.eventLoop.makeCompletedFuture {
          let handshake = channel.eventLoop.makePromise(of: Void.self)
          let pipeline = channel.pipeline.syncOperations
          try pipeline.addHandler(NIOSSLClientHandler(context: context, serverHostname: serverHostname))
          try pipeline.addHandler(HandshakeObserver(handshake: handshake))
          attempts.withLock { $0[ObjectIdentifier(channel)] = handshake.futureResult }
          return channel
        }
      }
    let handshake = attempts.withLock { $0[ObjectIdentifier(channel)] }
    guard let handshake else {
      try? await channel.close()
      throw SystemTrustError.connectionClosedBeforeHandshake
    }
    if let timeout {
      // A server that accepts TCP but never speaks TLS must not hang the
      // probe: the deadline bounds the handshake wait, not just the connect.
      let deadline = channel.eventLoop.scheduleTask(in: timeout) {
        channel.pipeline.fireErrorCaught(SystemTrustError.handshakeTimedOut)
        channel.close(promise: nil)
      }
      handshake.whenComplete { _ in deadline.cancel() }
    }
    do {
      try await handshake.get()
    } catch {
      try? await channel.close()
      throw error
    }
    try? await channel.close()
  }
}

private final class HandshakeObserver: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let handshake: EventLoopPromise<Void>
  private var completed = false

  init(handshake: EventLoopPromise<Void>) {
    self.handshake = handshake
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case .handshakeCompleted = event as? TLSUserEvent, !completed {
      completed = true
      handshake.succeed(())
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    fail(error)
    context.close(promise: nil)
  }

  // channelInactive never fires on a channel torn down before it went active
  // (a refused connect, a happy-eyeballs loser); handlerRemoved always does.
  func handlerRemoved(context: ChannelHandlerContext) {
    fail(SystemTrustError.connectionClosedBeforeHandshake)
  }

  private func fail(_ error: any Error) {
    guard !completed else { return }
    completed = true
    handshake.fail(error)
  }
}
