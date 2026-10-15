#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct WorkerProtocol.WorkerProtocolError

enum ParentCheckpointJSON {
  static func validateKeys(_ data: Data) throws {
    try data.withUnsafeBytes { raw in
      var scanner = KeyScanner(bytes: raw.bindMemory(to: UInt8.self))
      try scanner.value(depth: 0)
      scanner.whitespace()
      guard scanner.index == scanner.bytes.count else { throw invalid() }
    }
  }

  private static func invalid() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Invalid parent exec checkpoint")
  }

  private struct KeyScanner {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    mutating func whitespace() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws {
      whitespace()
      guard index < bytes.count, depth < 512 else { throw invalid() }
      switch bytes[index] {
      case 123:
        index += 1
        var keys: Set<String> = []
        if consume(125) { return }
        repeat {
          whitespace()
          let range = try string()
          let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
          guard keys.insert(key).inserted, consume(58) else { throw invalid() }
          try value(depth: depth + 1)
          if consume(125) { return }
          guard consume(44) else { throw invalid() }
        } while true
      case 91:
        index += 1
        if consume(93) { return }
        repeat {
          try value(depth: depth + 1)
          if consume(93) { return }
          guard consume(44) else { throw invalid() }
        } while true
      case 34: _ = try string()
      default:
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw invalid() }
      }
    }

    mutating func string() throws -> Range<Int> {
      guard index < bytes.count, bytes[index] == 34 else { throw invalid() }
      let start = index
      index += 1
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 { return start ..< index }
        if byte == 92 {
          guard index < bytes.count else { throw invalid() }
          index += 1
        }
      }
      throw invalid()
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      whitespace()
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }
  }
}
