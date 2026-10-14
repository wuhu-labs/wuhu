#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SystemPackage

public struct AttemptLogConfig: Sendable {
  public var directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public var traceClient: AttemptTraceClient {
    AttemptTraceClient { id in
      let file = try AttemptLogFile(url: directory.appendingPathComponent("\(id.uuidString.lowercased()).log"))
      return AttemptTraceSink { await file.append($0) }
    }
  }
}

private actor AttemptLogFile {
  private let handle: FileDescriptor

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    handle = try FileDescriptor.open(FilePath(url.path), .writeOnly, options: [.create, .truncate], permissions: [.ownerRead, .ownerWrite])
  }

  deinit { try? handle.close() }

  func append(_ data: Data) {
    _ = try? data.withUnsafeBytes { try handle.writeAll($0) }
  }
}
