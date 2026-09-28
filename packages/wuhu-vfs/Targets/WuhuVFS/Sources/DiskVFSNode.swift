import Foundation
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import NIOCore
import NIOPosix

// MARK: - Shared NIO thread pool

/// A lazily-initialized, shared thread pool for all ``DiskVFSNode`` instances.
/// Routes blocking file I/O off Swift's cooperative thread pool, preventing
/// thread starvation under load.
private enum DiskIOPool {
  static let threadPool: NIOThreadPool = {
    let pool = NIOThreadPool(numberOfThreads: max(2, min(16, ProcessInfo.processInfo.activeProcessorCount)))
    pool.start()
    return pool
  }()

  static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// Offload a blocking operation onto the shared ``DiskIOPool`` thread pool,
/// yielding an async result back to the Swift concurrency runtime.
private func offload<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T,
) async throws -> T {
  let eventLoop = DiskIOPool.eventLoopGroup.next()
  return try await DiskIOPool.threadPool.runIfActive(eventLoop: eventLoop) {
    try operation()
  }.get()
}

/// A `VFSNode` backed by a real directory on the local filesystem.
///
/// Navigation is structural: `openChild` returns a child handle cheaply
/// by appending to the path. `status` calls `stat(2)` to determine
/// existence and kind. `readData` and `writeData` delegate to Foundation file I/O.
/// All blocking I/O is routed through a shared ``DiskIOPool`` NIO thread pool
/// to avoid starving the Swift cooperative thread pool.
///
/// There is no symlink kind: `stat(2)` follows a host symlink to its target, so
/// a symlink-to-file reports `.file` and a dangling symlink reports `notFound`.
public struct DiskVFSNode: VFSNode {
  public let path: String
  public let isMutable: Bool

  public init(path: String, isMutable: Bool) {
    self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    self.isMutable = isMutable
  }

  // MARK: - Identity

  public var status: VFSNodeStatus? {
    get async throws {
      try await offload {
        do {
          // `stat` follows host symlinks to their target; a dangling symlink
          // reports `notFound`. No symlink kind is ever surfaced.
          let s = try diskStatus(at: path)
          return VFSNodeStatus(
            kind: s.kind,
            size: s.size,
            modifiedAt: s.modifiedAt,
            accessedAt: s.accessedAt,
            createdAt: s.createdAt,
            mode: s.mode,
            uid: s.uid,
            gid: s.gid,
          )
        } catch VFSNodeError.notFound {
          return nil
        }
      }
    }
  }

  // MARK: - Navigation

  public func children() async throws -> [VFSDirectoryEntry] {
    try await offload {
      let s = try diskStatus(at: path)
      guard s.kind == .directory else {
        throw VFSNodeError.notADirectory
      }

      let names = try FileManager.default.contentsOfDirectory(atPath: path)
      var entries: [VFSDirectoryEntry] = []
      entries.reserveCapacity(names.count)

      for name in names.sorted() {
        let childPath = URL(fileURLWithPath: path)
          .appendingPathComponent(name, isDirectory: false)
          .standardizedFileURL.path

        // `stat` per child follows symlinks to their target kind.
        let childStatus = try? diskStatus(at: childPath)
        entries.append(VFSDirectoryEntry(
          name: name,
          kind: childStatus?.kind ?? .file,
        ))
      }

      return entries
    }
  }

  public func childNode(_ name: String) async throws -> (any VFSNode)? {
    try VFSPathComponent.require(name)
    let childPath = URL(fileURLWithPath: path)
      .appendingPathComponent(name, isDirectory: false)
      .standardizedFileURL.path
    return DiskVFSNode(path: childPath, isMutable: isMutable)
  }

  // MARK: - Data

  public func readData() async throws -> Data {
    try await offload {
      let s = try diskStatus(at: path)
      guard s.kind == .file else {
        throw VFSNodeError.notAFile
      }
      return try Data(contentsOf: URL(fileURLWithPath: path))
    }
  }

  public func writeData(_ data: Data, append: Bool) async throws {
    guard isMutable else { throw VFSNodeError.immutable }

    try await offload {
      if append {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      }
    }
  }

  // MARK: - Creation

  public func createFile(_ name: String, data: Data) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    guard isMutable else { throw VFSNodeError.immutable }
    let childPath = URL(fileURLWithPath: path)
      .appendingPathComponent(name, isDirectory: false)
      .standardizedFileURL.path

    try await offload {
      guard !FileManager.default.fileExists(atPath: childPath) else {
        throw VFSNodeError.forbidden // already exists
      }

      try data.write(to: URL(fileURLWithPath: childPath), options: .atomic)
    }
    return DiskVFSNode(path: childPath, isMutable: isMutable)
  }

  public func createDirectory(_ name: String) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    guard isMutable else { throw VFSNodeError.immutable }
    let childPath = URL(fileURLWithPath: path)
      .appendingPathComponent(name, isDirectory: true)
      .standardizedFileURL.path

    try await offload {
      try FileManager.default.createDirectory(atPath: childPath, withIntermediateDirectories: false)
    }
    return DiskVFSNode(path: childPath, isMutable: isMutable)
  }

  // MARK: - Removal

  public func remove(recursive: Bool) async throws {
    guard isMutable else { throw VFSNodeError.immutable }

    try await offload {
      let s = try diskStatus(at: path)
      if s.kind == .directory, !recursive {
        // An empty directory may be removed non-recursively; a non-empty one
        // requires the recursive flag. `removeItem` itself recurses.
        let children = try FileManager.default.contentsOfDirectory(atPath: path)
        guard children.isEmpty else {
          throw VFSError.directoryNotEmpty(path: path)
        }
      }
      try FileManager.default.removeItem(atPath: path)
    }
  }

  // MARK: - Fast-path operations

  public func rename(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    guard isMutable else { throw VFSNodeError.immutable }

    // Only fast-path if source is also a DiskVFSNode
    guard let diskSource = source as? DiskVFSNode else {
      return false
    }

    let destPath = URL(fileURLWithPath: path)
      .appendingPathComponent(name, isDirectory: false)
      .standardizedFileURL.path

    try await offload {
      try FileManager.default.moveItem(atPath: diskSource.path, toPath: destPath)
    }
    return true
  }

  public func copy(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    guard isMutable else { throw VFSNodeError.immutable }

    guard let diskSource = source as? DiskVFSNode else {
      return false
    }

    let destPath = URL(fileURLWithPath: path)
      .appendingPathComponent(name, isDirectory: false)
      .standardizedFileURL.path

    try await offload {
      try FileManager.default.copyItem(atPath: diskSource.path, toPath: destPath)
    }
    return true
  }
}

// MARK: - Disk status

private struct DiskStatus {
  var kind: VFSNodeKind
  var size: Int64
  var modifiedAt: Date
  var accessedAt: Date
  var createdAt: Date
  var mode: UInt16
  var uid: UInt32
  var gid: UInt32
}

private func diskStatus(at path: String) throws -> DiskStatus {
  var info = stat()
  errno = 0
  // `stat` follows symlinks to their target; a dangling symlink is `notFound`.
  let result = path.withCString { fileSystemPath in
    stat(fileSystemPath, &info)
  }

  guard result == 0 else {
    switch errno {
    case ENOENT, ENOTDIR:
      throw VFSNodeError.notFound
    default:
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  let kind: VFSNodeKind = switch info.st_mode & S_IFMT {
  case S_IFDIR:
    .directory
  default:
    .file
  }

  func timevalToDate(_ tv: timeval) -> Date {
    Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
  }

  #if canImport(Darwin)
    let modifiedAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
    )
    let accessedAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)
        + TimeInterval(info.st_atimespec.tv_nsec) / 1_000_000_000,
    )
    let createdAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
        + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000,
    )
  #else
    let modifiedAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec)
        + TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000,
    )
    let accessedAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_atim.tv_sec)
        + TimeInterval(info.st_atim.tv_nsec) / 1_000_000_000,
    )
    let createdAt = Date(
      timeIntervalSince1970: TimeInterval(info.st_ctim.tv_sec)
        + TimeInterval(info.st_ctim.tv_nsec) / 1_000_000_000,
    )
  #endif

  return DiskStatus(
    kind: kind,
    size: Int64(info.st_size),
    modifiedAt: modifiedAt,
    accessedAt: accessedAt,
    createdAt: createdAt,
    mode: UInt16(info.st_mode & 0o7777),
    uid: info.st_uid,
    gid: info.st_gid,
  )
}
