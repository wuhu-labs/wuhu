#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

let stagePrefix = ".wuhu-write-"

/// The write stages an agent holds open, so its next run removes those a crashed run left behind. An entry is named by its
/// stage's UUID and holds the stage's folder: it owns exactly `<folder>/.wuhu-write-<UUID>`, never a path of its own choosing.
/// Only the agent holding the operations-root lock that covers the ledger sweeps it.
public struct StageLedger: Sendable {
  let directory: String

  public init(directory: String) throws {
    guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw diskError() }
    self.directory = directory
  }

  /// Durable before the stage exists.
  func record(_ stage: UUID, in folder: String) throws {
    let entry = directory + "/" + stage.uuidString
    let fd = open(entry, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw diskError() }
    defer { closeDescriptor(fd) }
    let bytes = Array(folder.utf8)
    #if os(Linux)
      let written = Glibc.write(fd, bytes, bytes.count)
    #else
      let written = Darwin.write(fd, bytes, bytes.count)
    #endif
    guard written == bytes.count, fsync(fd) == 0 else {
      let error = diskError()
      _ = unlink(entry)
      throw error
    }
  }

  /// Only once the stage is renamed into place, unlinked or confirmed absent.
  func forget(_ stage: UUID) { _ = unlink(directory + "/" + stage.uuidString) }

  /// Removes every recorded stage still on disk; an entry goes once its stage is gone, and stays while that is uncertain.
  /// Returns how many stages it removed.
  @discardableResult public func sweep() -> Int {
    var removed = 0
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
      guard let stage = UUID(uuidString: name), stage.uuidString == name,
            let data = FileManager.default.contents(atPath: directory + "/" + name) else { continue }
      let folder = String(decoding: data, as: UTF8.self)
      guard folder.hasPrefix("/") else { continue }
      let parent = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard parent >= 0 else {
        if errno == ENOENT { forget(stage) }
        continue
      }
      defer { closeDescriptor(parent) }
      guard let unlinked = removeStage(parent, stagePrefix + name) else { continue }
      if unlinked { removed += 1 }
      forget(stage)
    }
    return removed
  }
}

/// Unlinks the regular file `name` in `parent` without following a symlink: true once unlinked, false when absent, nil when it
/// may still be there (not a regular file, or the unlink failed).
func removeStage(_ parent: Int32, _ name: String) -> Bool? {
  var info = stat()
  guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? false : nil }
  guard info.st_mode & S_IFMT == S_IFREG else { return nil }
  if unlinkat(parent, name, 0) == 0 { return true }
  return errno == ENOENT ? false : nil
}
