import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

private let alphanumericAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

/// The random suffix an id mints: lowercase alphanumerics, never sequential.
public func randomAlphanumericSuffix(_ count: Int, using generator: inout some RandomNumberGenerator) -> String {
  String((0 ..< count).map { _ in alphanumericAlphabet.randomElement(using: &generator)! })
}

extension UUID {
  /// The id derived from what a retried call names: the same parts, the same id.
  public static func deterministic(_ parts: String...) -> UUID {
    let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    ))
  }
}
