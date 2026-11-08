/// Where a copy's bytes come from: a file on a machine, or bytes the caller already holds.
public enum CopySource: Sendable, Equatable {
  case machine(MachineID, path: String)
  case bytes([UInt8])
}

/// Where a copy's bytes land: a file on a machine, replacing one already there only with `replace`, or back with the caller,
/// refused up front when the source is over `limit` bytes.
public enum CopyTarget: Sendable, Equatable {
  case machine(MachineID, path: String, replace: Bool)
  case caller(limit: Int)
}

public struct CopyReceipt: Sendable, Equatable {
  public enum Landing: Sendable, Equatable {
    /// The target file's version token.
    case machine(token: String)
    case caller([UInt8])
  }

  public let bytes: Int
  /// Lowercase hex sha256 of every byte copied.
  public let sha256: String
  public let landing: Landing
  public init(bytes: Int, sha256: String, landing: Landing) { self.bytes = bytes; self.sha256 = sha256; self.landing = landing }
}

/// A copy refused for what is at its ends; a failure to reach a machine is that machine's own error.
public enum CopyRefusal: Error, Sendable, Equatable {
  public enum End: Sendable, Equatable { case source, target }
  case missing(End)
  case io(End, errno: Int)
  case sourceNotAFile
  case sourceChanged
  case sourceTooLarge(size: Int, limit: Int)
  case targetExists
  /// The machine's agent predates staged writes.
  case unsupported(MachineID)
}
