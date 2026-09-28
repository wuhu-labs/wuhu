#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
import JSONValue
import OrderedCollections

public struct ClaudeCodeLog: Hashable, Sendable {
  public var sessionID: UUID
  public var entries: [OrderedDictionary<String, JSONValue>]

  public init(sessionID: UUID, entries: [OrderedDictionary<String, JSONValue>]) {
    self.sessionID = sessionID
    self.entries = entries
  }

  // Every `last-prompt` entry is left out. Claude Code resumes on the branch
  // the last one names, and one written while parallel tool calls were pending
  // can name a dead end, which drops every later turn.
  var contents: [UInt8] {
    var bytes: [UInt8] = []
    for entry in entries where entry["type"] != .string("last-prompt") {
      bytes += JSONValue.object(entry).jsonString().utf8
      bytes.append(UInt8(ascii: "\n"))
    }
    return bytes
  }

  // Writes `<configDirectory>/projects/<project folder>/<session id>.jsonl`, where
  // Claude Code will look for it when started in `workingFolder` with `--resume`.
  // Both folders must exist; the log file must not.
  @discardableResult
  public func write(configDirectory: String, workingFolder: String) async throws -> String {
    let folder = "\(configDirectory)/projects/\(Self.projectFolderName(workingFolder: try realPath(workingFolder)))"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let path = "\(folder)/\(sessionID.uuidString.lowercased()).jsonl"
    try Data(contents).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    return path
  }

  // Claude Code's own encoding, over UTF-16 code units because it is JavaScript:
  // every unit outside [A-Za-z0-9] becomes "-", and past 200 units the name is
  // cut and suffixed with a 32-bit string hash in base 36.
  static func projectFolderName(workingFolder: String) -> String {
    #if canImport(Darwin)
      let path = Array(workingFolder.precomposedStringWithCanonicalMapping.utf16)
    #else
      let path = Array(workingFolder.utf16)
    #endif
    let sanitized = path.map { unit -> UInt8 in
      switch unit {
      case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A: UInt8(unit)
      default: UInt8(ascii: "-")
      }
    }
    guard sanitized.count > 200 else { return String(decoding: sanitized, as: UTF8.self) }
    let hash = path.reduce(Int32(0)) { hash, unit in (hash &<< 5) &- hash &+ Int32(unit) }
    return String(decoding: sanitized.prefix(200), as: UTF8.self) + "-" + String(hash.magnitude, radix: 36)
  }
}

private func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else {
    throw CocoaError(.fileReadNoSuchFile)
  }
  defer { free(resolved) }
  return String(cString: resolved)
}
