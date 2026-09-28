#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto

typealias SHA256 = Crypto.SHA256

extension SHA256 {
  static func hex(_ string: String) -> String {
    self.hex(Array(string.utf8))
  }

  static func hex(_ bytes: some DataProtocol) -> String {
    Self.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
