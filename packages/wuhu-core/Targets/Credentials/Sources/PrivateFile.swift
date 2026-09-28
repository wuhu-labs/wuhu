#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// Drops group and other bits from an existing path's mode; a missing path is
// left alone.
func tightenToOwnerOnly(_ path: String) throws {
  var info = stat()
  guard lstat(path, &info) == 0 else { return }
  let mode = info.st_mode & 0o777
  guard mode & 0o077 != 0 else { return }
  guard chmod(path, mode & 0o700) == 0 else {
    throw CredentialsStoreError(message: "cannot tighten \(path): \(String(cString: strerror(errno)))")
  }
}

struct PrivateFile: Sendable {
  let directory: URL
  let stem: String

  var url: URL {
    directory.appendingPathComponent("\(stem).json")
  }

  func read() throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  func replace(with data: Data) throws {
    try makeDirectory()
    let temp = directory.appendingPathComponent(".\(stem).json.tmp")
    guard FileManager.default.createFile(
      atPath: temp.path,
      contents: data,
      attributes: [.posixPermissions: 0o600],
    ) else {
      throw CredentialsStoreError(message: "cannot write \(temp.path)")
    }
    guard rename(temp.path, url.path) == 0 else {
      let error = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: temp)
      throw CredentialsStoreError(message: "cannot replace \(url.path): \(error)")
    }
  }

  func withLock<T>(_ body: () async throws -> T) async throws -> T {
    try makeDirectory()
    let lockPath = directory.appendingPathComponent(".\(stem).lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      throw CredentialsStoreError(message: "cannot open lock file \(lockPath)")
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw CredentialsStoreError(message: "cannot lock \(lockPath)")
    }
    defer { flock(fd, LOCK_UN) }
    return try await body()
  }

  private func makeDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
  }
}
