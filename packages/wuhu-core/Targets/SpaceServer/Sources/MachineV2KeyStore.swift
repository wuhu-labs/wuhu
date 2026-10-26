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
import Crypto
import struct OperationProtocol.OperationError
import class SpaceCore.Space

enum MachineV2KeyStore {
  static let filename = "machine-v2.key"

  static func loadOrCreate(from store: KeyFileStore, space: Space) async throws -> SymmetricKey {
    do {
      let key: SymmetricKey
      if let bytes = try await store.load() {
        guard bytes.count == 32 else { throw OperationError(.storeUnavailable) }
        key = SymmetricKey(data: bytes)
      } else {
        guard try await !space.machineV2HasEncryptedState() else { throw OperationError(.storeUnavailable) }
        key = SymmetricKey(size: .bits256)
        try await store.create(key.withUnsafeBytes { Data($0) })
      }
      try await space.validateMachineV2Key(key)
      return key
    } catch { throw OperationError(.storeUnavailable, message: "Machine v2 durable key is unavailable; restore the server state key backup") }
  }

  static func loadOrCreate(directory: URL, space: Space) async throws -> SymmetricKey {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw OperationError(.storeUnavailable) }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let file = directory.appendingPathComponent(filename)
      var info = stat()
      if lstat(file.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size == 32 else { throw OperationError(.storeUnavailable) }
      } else if errno != ENOENT { throw OperationError(.storeUnavailable) }
      let key = try await loadOrCreate(from: .disk(file), space: space)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      try synchronize(file.path)
      try synchronize(directory.path)
      return key
    } catch { throw OperationError(.storeUnavailable, message: "Machine v2 durable key is unavailable; restore the server state key backup") }
  }

  private static func synchronize(_ path: String) throws {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw OperationError(.storeUnavailable) }
    defer { _ = close(fd) }
    guard fsync(fd) == 0 else { throw OperationError(.storeUnavailable) }
  }
}
