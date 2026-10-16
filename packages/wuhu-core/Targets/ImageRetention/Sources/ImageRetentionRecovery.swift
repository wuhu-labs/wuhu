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
  func recover() throws {
    let names = try names()
    for name in names where name.hasPrefix(".stage-") { try recoverStage(name, names: names) }
    let references = try references()
    try recoverPreparations(references, names: names)
    let retained = Set(try self.references().map(\.digest))
    for name in names where Self.isDigest(name) && !retained.contains(name) {
      let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard file >= 0 else { throw ImageRetentionError.unsafeStorage }
      defer { _ = close(file) }
      try Self.validateFile(file, mode: 0o500)
      guard try Self.digest(file) == name else { throw ImageRetentionError.imageChanged }
      guard unlinkat(descriptor, name, 0) == 0 else { throw ImageRetentionError.unsafeStorage }
    }
    guard fsync(descriptor) == 0 else { throw ImageRetentionError.unsafeStorage }
  }

  private func recoverStage(_ name: String, names: [String]) throws {
    guard let id = UUID(uuidString: String(name.dropFirst(7))), name == ".stage-" + id.uuidString else { throw ImageRetentionError.invalidEvidence }
    var stage = stat()
    guard fstatat(descriptor, name, &stage, AT_SYMLINK_NOFOLLOW) == 0,
          stage.st_uid == geteuid(), stage.st_mode & S_IFMT == S_IFREG,
          [mode_t(0o600), mode_t(0o500)].contains(stage.st_mode & 0o7777),
          stage.st_nlink == 1 || stage.st_nlink == 2 else { throw ImageRetentionError.unsafeStorage }
    if stage.st_nlink == 2 {
      let peers = names.filter { candidate in
        guard candidate != name else { return false }
        var state = stat()
        return fstatat(descriptor, candidate, &state, AT_SYMLINK_NOFOLLOW) == 0 && state.st_dev == stage.st_dev && state.st_ino == stage.st_ino
      }
      guard peers.count == 1, let peer = peers.first else { throw ImageRetentionError.invalidEvidence }
      if stage.st_mode & 0o7777 == 0o500 {
        guard Self.isDigest(peer) else { throw ImageRetentionError.invalidEvidence }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw ImageRetentionError.unsafeStorage }
        defer { _ = close(file) }
        guard try Self.digest(file) == peer else { throw ImageRetentionError.imageChanged }
      } else {
        guard peer.hasSuffix(".json"), let id = UUID(uuidString: String(peer.dropLast(5))), peer == id.uuidString + ".json" else { throw ImageRetentionError.invalidEvidence }
        let reference = try read(peer, links: 2)
        try reference.validate()
        guard reference.id == id else { throw ImageRetentionError.invalidEvidence }
      }
    }
    guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else { throw ImageRetentionError.unsafeStorage }
  }

  private static func isDigest(_ name: String) -> Bool {
    name.count == 64 && name.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
  }
}
