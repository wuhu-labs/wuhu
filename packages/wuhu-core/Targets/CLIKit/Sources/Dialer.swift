#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum FetchWebSocket.ClientTLS
import enum FetchWebSocket.WebSocketClient
import struct FetchWebSocket.WebSocketDuplex
import protocol MachineChannel.FrameTransport

extension SpaceTransport {
  public static func webSocketTransport(
    trust: ServerTrust,
    maxFrameBytes: Int,
  ) -> @Sendable (URL, [(String, String)]) async throws -> any FrameTransport {
    { url, headers in
      do {
        let tls: ClientTLS? = try self.recordedPin(url: url, trust: trust)
          .map { .pinned(fingerprint: $0) }
        return WebSocketFrameTransport(socket: try await WebSocketClient.connect(
          url: url,
          headers: headers,
          maxFrameBytes: maxFrameBytes,
          tls: tls,
        ))
      } catch {
        throw await self.diagnosed(error, url: url, trust: trust)
      }
    }
  }
}

struct WebSocketFrameTransport: FrameTransport {
  let socket: WebSocketDuplex

  var inbound: AsyncStream<[UInt8]> {
    self.socket.inbound
  }

  func send(_ frame: [UInt8]) async throws {
    try await self.socket.send(frame)
  }

  func close() {
    self.socket.close()
  }
}
