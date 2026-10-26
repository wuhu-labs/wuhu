#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

struct KeyFileStore: Sendable {
  var load: @Sendable () async throws -> Data?
  var create: @Sendable (Data) async throws -> Void

  static func disk(_ file: URL) -> Self {
    Self(load: {
      var info = stat()
      guard lstat(file.path, &info) == 0 else {
        if errno == ENOENT { return nil }
        throw IdentityError.keyUnavailable
      }
      guard info.st_mode & S_IFMT == S_IFREG else { throw IdentityError.keyUnavailable }
      let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { throw IdentityError.keyUnavailable }
      defer { _ = close(fd) }
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw IdentityError.keyUnavailable }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw IdentityError.keyUnavailable }
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
      }
    }, create: { data in
      try createExclusive(data, at: file.path)
      let fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw IdentityError.keyUnavailable }
      defer { _ = close(fd) }
      guard fsync(fd) == 0 else { throw IdentityError.keyUnavailable }
    })
  }

  private static func createExclusive(_ data: Data, at path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw IdentityError.keyUnavailable }
    defer { _ = close(fd) }
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw IdentityError.keyUnavailable }
        written += count
      }
    }
    guard fsync(fd) == 0 else { throw IdentityError.keyUnavailable }
  }
}
