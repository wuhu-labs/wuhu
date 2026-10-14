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
import struct WuhuVFS.DiskVFSNode
import struct WuhuVFS.NodeTreeVFS
import struct WuhuVFS.VFSPath
import protocol WuhuVFS.VirtualFileSystem

enum MachineV2KeyStore {
  static let filename = "machine-v2.key"

  static func loadOrCreate(from fs: any VirtualFileSystem, space: Space) async throws -> SymmetricKey {
    try await loadOrCreate(from: fs, space: space) { data in
      try await fs.createFile(at: VFSPath(absoluteFilePath: "/" + filename), data: data)
    }
  }

  private static func loadOrCreate(
    from fs: any VirtualFileSystem,
    space: Space,
    create: @Sendable (Data) async throws -> Void,
  ) async throws -> SymmetricKey {
    do {
      let path = try VFSPath(absoluteFilePath: "/" + filename)
      let key: SymmetricKey
      if let status = try await fs.status(at: path) {
        guard status.kind == .file, status.size == 32 else { throw OperationError(.storeUnavailable) }
        let bytes = try await fs.readData(at: path)
        guard bytes.count == 32 else { throw OperationError(.storeUnavailable) }
        key = SymmetricKey(data: bytes)
      } else {
        guard try await !space.machineV2HasEncryptedState() else { throw OperationError(.storeUnavailable) }
        key = SymmetricKey(size: .bits256)
        try await create(key.withUnsafeBytes { Data($0) })
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
        guard info.st_mode & S_IFMT == S_IFREG else { throw OperationError(.storeUnavailable) }
      } else if errno != ENOENT { throw OperationError(.storeUnavailable) }
      let key = try await loadOrCreate(from: NodeTreeVFS(root: DiskVFSNode(path: directory.path, isMutable: true)), space: space) { data in
        try createExclusive(data, at: file.path)
        try synchronize(directory.path)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      try synchronize(file.path)
      try synchronize(directory.path)
      return key
    } catch { throw OperationError(.storeUnavailable, message: "Machine v2 durable key is unavailable; restore the server state key backup") }
  }

  private static func createExclusive(_ data: Data, at path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw OperationError(.storeUnavailable) }
    defer { _ = close(fd) }
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw OperationError(.storeUnavailable) }
        written += count
      }
    }
    guard fsync(fd) == 0 else { throw OperationError(.storeUnavailable) }
  }

  private static func synchronize(_ path: String) throws {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw OperationError(.storeUnavailable) }
    defer { _ = close(fd) }
    guard fsync(fd) == 0 else { throw OperationError(.storeUnavailable) }
  }
}
