#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SystemPackage

/// Where the transcript-lines mismatch check appends one JSON line per difference.
public struct LineDifferenceLog: Sendable {
  public var append: @Sendable (Data) async -> Void

  public init(append: @escaping @Sendable (Data) async -> Void) {
    self.append = append
  }

  public static func file(_ url: URL) throws -> LineDifferenceLog {
    let file = try AppendedFile(url: url)
    return LineDifferenceLog { await file.append($0) }
  }
}

private actor AppendedFile {
  private let handle: FileDescriptor

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    handle = try FileDescriptor.open(FilePath(url.path), .writeOnly, options: [.create, .append], permissions: [.ownerRead, .ownerWrite])
  }

  deinit { try? handle.close() }

  func append(_ data: Data) {
    _ = try? data.withUnsafeBytes { try handle.writeAll($0) }
  }
}
