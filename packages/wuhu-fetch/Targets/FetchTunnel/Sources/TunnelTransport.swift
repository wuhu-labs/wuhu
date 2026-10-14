#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch

public struct TunnelTransport: Sendable {
  public static let webSocketSubprotocol = "wuhu-fetch-tunnel.v1"
  public let maxMessageBytes: Int
  public let receive: @Sendable () async throws -> Bytes?
  public let send: @Sendable (Bytes) async throws -> Void
  public let abort: @Sendable () -> Void

  public init(
    maxMessageBytes: Int = 1 << 20,
    receive: @escaping @Sendable () async throws -> Bytes?,
    send: @escaping @Sendable (Bytes) async throws -> Void,
    abort: @escaping @Sendable () -> Void,
  ) {
    self.maxMessageBytes = maxMessageBytes
    self.receive = receive
    self.send = send
    self.abort = abort
  }
}

public struct TunnelLimits: Sendable, Equatable {
  public var headBytes: Int
  public var chunkBytes: Int
  public var bodyBytes: Int
  public var streams: Int

  public init(headBytes: Int = 32 << 10, chunkBytes: Int = 16 << 10, bodyBytes: Int = 1 << 20, streams: Int = 32) {
    self.headBytes = headBytes
    self.chunkBytes = chunkBytes
    self.bodyBytes = bodyBytes
    self.streams = streams
  }

  func validate(maxMessageBytes: Int = 1 << 20) throws {
    guard headBytes > 0, headBytes <= 1 << 20, chunkBytes > 0, chunkBytes <= 1 << 20,
          bodyBytes >= 0, bodyBytes <= 64 << 20, streams > 0, streams <= 1024,
          max(headBytes, chunkBytes, 128) + 10 <= maxMessageBytes
    else { throw TunnelError.invalidConfiguration }
  }
}

public enum TunnelError: String, Error, Sendable, Codable, Equatable {
  case invalidConfiguration
  case capacityExceeded
  case headTooLarge
  case bodyTooLarge
  case protocolViolation
  case corruptFraming
  case connectionClosed
  case cancelled
  case handlerFailed
  case unsupportedTransport
  case unsupportedSubprotocol
  case webSocketLimitExceeded
  case transportFailure
  case alreadyRunning
}
