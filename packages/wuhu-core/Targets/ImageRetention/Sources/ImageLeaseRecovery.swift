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

extension ImageRetention {
  func openRetiredPreparation(_ reference: ImageReference) throws -> Int32 {
    let file = try openLease(".lease-" + reference.id.uuidString)
    guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
      let busy = errno == EWOULDBLOCK || errno == EAGAIN
      _ = close(file)
      throw busy ? ImageRetentionError.processStillLive : ImageRetentionError.unsafeStorage
    }
    return file
  }

  func openLease(_ name: String) throws -> Int32 {
    guard let id = UUID(uuidString: String(name.dropFirst(7))), name == ".lease-" + id.uuidString else { throw ImageRetentionError.invalidEvidence }
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else { throw ImageRetentionError.invalidEvidence }
    do {
      try Self.validateFile(file, mode: 0o600)
      var state = stat()
      guard fstat(file, &state) == 0, state.st_size == 0 else { throw ImageRetentionError.invalidEvidence }
      return file
    } catch { _ = close(file); throw error }
  }

  func recoverPreparations(_ references: [ImageReference], names: [String]) throws {
    for name in names where name.hasPrefix(".lease-") {
      let file = try openLease(name)
      defer { _ = close(file) }
      if flock(file, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ImageRetentionError.unsafeStorage }
        continue
      }
      let id = UUID(uuidString: String(name.dropFirst(7)))!
      if let reference = references.first(where: { $0.id == id }) {
        if let pid = reference.processID, let birth = reference.birth {
          if kill(pid, 0) == 0 || errno != ESRCH {
            guard let actual = try? imageProcessBirth(pid), actual != birth else { continue }
          }
        }
        guard unlinkat(descriptor, id.uuidString + ".json", 0) == 0 else { throw ImageRetentionError.unsafeStorage }
      }
      guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw ImageRetentionError.unsafeStorage }
    }
  }
}
