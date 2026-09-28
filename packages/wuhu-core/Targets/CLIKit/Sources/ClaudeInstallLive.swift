#if canImport(FoundationEssentials)
  import class Foundation.FileHandle
  import class Foundation.Process
  import FoundationEssentials
#else
  import Foundation
#endif

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

import Dependencies
import WuhuVFS

extension ClaudeInstallEnvironment: DependencyKey {
  static var liveValue: ClaudeInstallEnvironment {
    @Dependency(\.fetch) var fetch
    return ClaudeInstallEnvironment(
      fetch: fetch,
      extract: { archive, member in
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wuhu-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("archive.tgz")
        let result = folder.appendingPathComponent("member")
        try archive.write(to: source)
        guard FileManager.default.createFile(atPath: result.path, contents: nil) else {
          throw ClaudeExtractionError(message: "cannot create Claude Code extraction output")
        }
        let output = try FileHandle(forWritingTo: result)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-xzOf", source.path, member]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
          process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
          do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw ClaudeExtractionError(message: "tar could not extract \(member) (exit \(status))") }
        return try Data(contentsOf: result)
      },
      filesystem: NodeTreeVFS(root: DiskVFSNode(path: "/", isMutable: true)),
      makeExecutable: { path in
        guard chmod(path, 0o700) == 0 else {
          throw ClaudeExtractionError(message: "cannot make Claude Code executable at \(path)")
        }
      },
    )
  }
}

private struct ClaudeExtractionError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}
