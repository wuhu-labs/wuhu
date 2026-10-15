import CryptoKit
import Darwin
import Foundation

/// A one-connection WebSocket server on raw sockets, so a test controls frame order that ServeNIO keeps correct.
final class RawWebSocketPeer: @unchecked Sendable {
  let port: UInt16
  private let listener: Int32
  private let dropped = DispatchSemaphore(value: 0)

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    guard fd >= 0, bound == 0, listen(fd, 1) == 0,
          withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0
    else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
    listener = fd
    port = UInt16(bigEndian: address.sin_port)
  }

  deinit { close(listener) }

  /// What the peer sends right after the upgrade, ahead of any pong.
  enum Lead {
    /// One binary message. The client has not received it, so URLSession holds the pong back and the ping stays
    /// pending. The peer returns once the ping arrives.
    case message
    /// A close frame. URLSession then never calls the ping's pong handler. The peer returns once the client's first
    /// frame arrives, or after two seconds of silence.
    case closeFrame
  }

  /// Resets the connection that `serve(_:)` holds.
  func reset() { dropped.signal() }

  /// Accepts one client, completes the `wuhu-fetch-tunnel.v1` upgrade and sends `lead`. The connection stays open,
  /// unanswered, until `reset()` aborts it with a TCP reset.
  func serve(_ lead: Lead) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        let fd = Darwin.accept(self.listener, nil, nil)
        guard fd >= 0, let request = Self.readHead(fd) else { close(fd); continuation.resume(); return }
        let key = request.split(separator: "\r\n")
          .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
          .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let answer = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        Self.write(fd, Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(answer)\r\nSec-WebSocket-Protocol: wuhu-fetch-tunnel.v1\r\n\r\n".utf8))
        switch lead {
        case .message:
          Self.write(fd, [0x82, 0x03, 0x01, 0x02, 0x03])
          while let opcode = Self.readFrame(fd), opcode != 0x9 {}
        case .closeFrame:
          Self.write(fd, [0x88, 0x02, 0x03, 0xE8])
          var timeout = timeval(tv_sec: 2, tv_usec: 0)
          setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
          _ = Self.readFrame(fd)
        }
        continuation.resume()
        self.dropped.wait()
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(fd)
      }
    }
  }

  private static func write(_ fd: Int32, _ bytes: [UInt8]) {
    _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
  }

  private static func read(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let n = bytes[filled...].withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
      guard n > 0 else { return nil }
      filled += n
    }
    return bytes
  }

  private static func readHead(_ fd: Int32) -> String? {
    var head: [UInt8] = []
    while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
      guard let byte = read(fd, 1) else { return nil }
      head += byte
    }
    return String(decoding: head, as: UTF8.self)
  }

  /// Reads one masked client frame with a payload under 126 bytes and returns its opcode.
  private static func readFrame(_ fd: Int32) -> UInt8? {
    guard let header = read(fd, 2), header[1] & 0x7F < 126, read(fd, 4 + Int(header[1] & 0x7F)) != nil else { return nil }
    return header[0] & 0x0F
  }
}
