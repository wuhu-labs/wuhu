import Dependencies
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

// One server run's own folder, `<configDirectory>/runs/<spaceID>/<runID>`.
// Nothing here ever touches another run's folder: two servers of one space on
// one host (a copy under test, a restart overlapping its predecessor) share
// the parent and nothing else. The exclusive lock is held until the process
// exits, so a later sweep can tell a dead run from a live one.
struct ClaudeCodeRun: Sendable {
  let folder: String
  private let lock: Int32

  static func claim(configDirectory: URL, spaceID: String) throws -> ClaudeCodeRun {
    let folder = configDirectory
      .appendingPathComponent("runs")
      .appendingPathComponent(spaceID)
      .appendingPathComponent(runIdentifier().uuidString.lowercased())
      .path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let path = folder + "/lock"
    let fd = path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
    guard fd >= 0 else { throw ClaudeCodeRunError("cannot open \(path): errno \(errno)") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw ClaudeCodeRunError("\(path) is already locked")
    }
    return ClaudeCodeRun(folder: folder, lock: fd)
  }

  // Where one activation's `work/` and `config/` live.
  var activations: String { folder + "/claude" }
}

struct ClaudeCodeRunError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// A UUIDv7: the millisecond clock up front, so run folders sort by start.
func runIdentifier() -> UUID {
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  let milliseconds = UInt64(max(0, date.now.timeIntervalSince1970 * 1000))
  var bytes = uuid().uuid
  withUnsafeMutableBytes(of: &bytes) { raw in
    for index in 0 ..< 6 {
      raw[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
    }
    raw[6] = 0x70 | (raw[6] & 0x0F)
    raw[8] = 0x80 | (raw[8] & 0x3F)
  }
  return UUID(uuid: bytes)
}
