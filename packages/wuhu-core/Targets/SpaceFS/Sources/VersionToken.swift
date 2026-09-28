import struct Foundation.Data

public struct VersionToken: Hashable, Sendable {
  public let bytes: Data

  public init(_ bytes: Data) {
    self.bytes = bytes
  }
}
