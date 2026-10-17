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
import Crypto

/// Transactions share an on-disk lock with installers and pruners. References are never expired by age or PID alone.
public struct ImageRetention {
  public let root: String
  let descriptor: Int32

  public static func transaction<T>(root: String, _ body: (ImageRetention) throws -> T) throws -> T {
    try transaction(root: root, beforeLock: {}, body)
  }

  static func transaction<T>(root: String, beforeLock: () throws -> Void, _ body: (ImageRetention) throws -> T) throws -> T {
    let result: Result<T, any Error>
    do { result = try lockedTransaction(root: root, beforeLock: beforeLock) { store in Result { try body(store) } } }
    catch let error as ImageRetentionError { throw error }
    catch { throw ImageRetentionError.unsafeStorage }
    return try result.get()
  }

  private static func lockedTransaction<T>(root: String, beforeLock: () throws -> Void, _ body: (ImageRetention) throws -> T) throws -> T {
    guard root.hasPrefix("/"), !root.utf8.contains(0) else { throw ImageRetentionError.unsafeStorage }
    if mkdir(root, 0o700) != 0, errno != EEXIST { throw ImageRetentionError.unsafeStorage }
    let parent = open(URL(fileURLWithPath: root).deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw ImageRetentionError.unsafeStorage }
    defer { _ = close(parent) }
    guard fsync(parent) == 0 else { throw ImageRetentionError.unsafeStorage }
    let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw ImageRetentionError.unsafeStorage }
    defer { _ = close(directory) }
    var state = stat()
    guard fstat(directory, &state) == 0, state.st_uid == geteuid(), state.st_mode & 0o7777 == 0o700 else { throw ImageRetentionError.unsafeStorage }
    var lock = openat(directory, "lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    if lock < 0, errno == EEXIST {
      lock = openat(directory, "lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard lock >= 0 else { throw ImageRetentionError.unsafeStorage }
    defer { _ = close(lock) }
    try validateFile(lock, mode: 0o600)
    try beforeLock()
    while flock(lock, LOCK_EX) != 0 { if errno != EINTR { throw ImageRetentionError.unsafeStorage } }
    defer { _ = flock(lock, LOCK_UN) }
    var current = stat()
    guard lstat(root, &current) == 0, current.st_dev == state.st_dev, current.st_ino == state.st_ino else { throw ImageRetentionError.unsafeStorage }
    var locked = stat()
    guard fstat(lock, &locked) == 0, fstatat(directory, "lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
          current.st_dev == locked.st_dev, current.st_ino == locked.st_ino else { throw ImageRetentionError.unsafeStorage }
    try validateFile(lock, mode: 0o600)
    let store = Self(root: root, descriptor: directory)
    try store.recover()
    return try body(store)
  }

  public func imagePath(_ reference: ImageReference) throws -> String {
    try reference.validate()
    return root + "/" + reference.digest
  }

  public func references() throws -> [ImageReference] {
    let names = try names()
    return try names.compactMap { name in
      if name == "lock" || name.hasPrefix(".lease-") { return nil }
      if name.count == 64, name.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) { return nil }
      guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { throw ImageRetentionError.invalidEvidence }
      let reference = try read(name)
      try reference.validate()
      guard reference.id == id else { throw ImageRetentionError.invalidEvidence }
      return reference
    }
  }

  func names() throws -> [String] {
    do { return try FileManager.default.contentsOfDirectory(atPath: root) }
    catch { throw ImageRetentionError.unsafeStorage }
  }

  public func verify(_ reference: ImageReference) throws {
    guard try read(reference.id.uuidString + ".json") == reference else { throw ImageRetentionError.invalidEvidence }
    try verifyImage(reference)
  }

  public func verifyImage(_ reference: ImageReference) throws {
    try reference.validate()
    let file = openat(descriptor, reference.digest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else { throw ImageRetentionError.imageChanged }
    defer { _ = close(file) }
    try Self.validateFile(file, mode: 0o500)
    guard try Self.digest(file) == reference.digest else { throw ImageRetentionError.imageChanged }
  }

  /// Only an absent process or a positively different birth releases a bound reference. Uninspectable evidence stays pinned.
  public func release(_ reference: ImageReference) throws {
    var state = stat()
    if fstatat(descriptor, reference.id.uuidString + ".json", &state, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return }
    guard try read(reference.id.uuidString + ".json") == reference else { throw ImageRetentionError.invalidEvidence }
    if let pid = reference.processID, let birth = reference.birth {
      if kill(pid, 0) == 0 || errno != ESRCH {
        guard try imageProcessBirth(pid) != birth else { throw ImageRetentionError.processStillLive }
      }
    } else {
      let lease = try openRetiredPreparation(reference)
      _ = close(lease)
    }
    guard unlinkat(descriptor, reference.id.uuidString + ".json", 0) == 0, fsync(descriptor) == 0 else { throw ImageRetentionError.unsafeStorage }
    if try !references().contains(where: { $0.digest == reference.digest }) {
      try verifyImage(reference)
      guard unlinkat(descriptor, reference.digest, 0) == 0, fsync(descriptor) == 0 else { throw ImageRetentionError.unsafeStorage }
    }
  }

  public func protects(binary: String) throws -> Bool {
    let pins = try references()
    guard !pins.isEmpty else { return false }
    let file = open(binary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else { throw ImageRetentionError.imageChanged }
    defer { _ = close(file) }
    let digest = try Self.digest(file)
    return pins.contains { $0.digest == digest }
  }

  func read(_ name: String, links: nlink_t = 1) throws -> ImageReference {
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else { throw ImageRetentionError.invalidEvidence }
    defer { _ = close(file) }
    try Self.validateFile(file, mode: 0o600, links: links)
    var state = stat()
    guard fstat(file, &state) == 0, state.st_size > 0, state.st_size <= 4096 else { throw ImageRetentionError.invalidEvidence }
    var bytes = Data(count: Int(state.st_size))
    guard bytes.withUnsafeMutableBytes({ pread(file, $0.baseAddress!, $0.count, 0) }) == bytes.count else { throw ImageRetentionError.invalidEvidence }
    do { return try JSONDecoder().decode(ImageReference.self, from: bytes) }
    catch { throw ImageRetentionError.invalidEvidence }
  }

  static func validateFile(_ file: Int32, mode: mode_t, links: nlink_t = 1) throws {
    var state = stat()
    guard fstat(file, &state) == 0, state.st_uid == geteuid(), state.st_mode & S_IFMT == S_IFREG,
          state.st_mode & 0o7777 == mode, state.st_nlink == links else { throw ImageRetentionError.unsafeStorage }
  }

  static func digest(_ file: Int32) throws -> String {
    var hash = SHA256()
    var bytes = [UInt8](repeating: 0, count: 65536)
    var offset: off_t = 0
    while true {
      let count = pread(file, &bytes, bytes.count, offset)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw ImageRetentionError.imageChanged }
      if count == 0 { break }
      hash.update(data: bytes.prefix(count)); offset += off_t(count)
    }
    return hash.finalize().map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
  }
}
