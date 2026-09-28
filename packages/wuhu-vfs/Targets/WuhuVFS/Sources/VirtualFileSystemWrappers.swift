import Foundation

public extension VirtualFileSystem {
  /// A filesystem view that forwards reads and metadata while rejecting every
  /// mutation with ``VFSNodeError/immutable``.
  func readOnly() -> any VirtualFileSystem {
    ReadOnlyVFS(base: self)
  }

  /// A filesystem view rooted at `path` in this filesystem: every operation's
  /// path is resolved relative to `path`.
  func scoped(to path: VFSPath) -> any VirtualFileSystem {
    ScopedVFS(base: self, prefix: path)
  }
}

/// Forwards reads/metadata to `base`; rejects every mutation. Wraps the
/// `VirtualFileSystem` value directly — no node wrapping needed.
private struct ReadOnlyVFS: VirtualFileSystem {
  var base: any VirtualFileSystem

  func status(at path: VFSPath) async throws -> VFSNodeStatus? {
    try await base.status(at: path)
  }

  func children(of path: VFSPath) async throws -> [VFSDirectoryEntry] {
    try await base.children(of: path)
  }

  func readData(at path: VFSPath) async throws -> Data {
    try await base.readData(at: path)
  }

  func open(at path: VFSPath, mode: VFSOpenMode) async throws -> any VFSFileHandle {
    switch mode {
    case .read: try await base.open(at: path, mode: mode)
    case .write: throw VFSNodeError.immutable
    }
  }

  func writeData(_: Data, at _: VFSPath, append _: Bool) async throws {
    throw VFSNodeError.immutable
  }

  func createFile(at _: VFSPath, data _: Data) async throws {
    throw VFSNodeError.immutable
  }

  func createDirectory(at _: VFSPath, intermediates _: Bool) async throws {
    throw VFSNodeError.immutable
  }

  func remove(at _: VFSPath, recursive _: Bool) async throws {
    throw VFSNodeError.immutable
  }

  func move(from _: VFSPath, to _: VFSPath) async throws {
    throw VFSNodeError.immutable
  }

  func copy(from _: VFSPath, to _: VFSPath) async throws {
    throw VFSNodeError.immutable
  }
}

/// Re-roots every operation at `prefix` in `base`. Wraps the `VirtualFileSystem`
/// value directly: each path is prepended with the prefix before delegating.
private struct ScopedVFS: VirtualFileSystem {
  var base: any VirtualFileSystem
  var prefix: VFSPath

  private func resolve(_ path: VFSPath) -> VFSPath {
    VFSPath(components: prefix.components + path.components)
  }

  func status(at path: VFSPath) async throws -> VFSNodeStatus? {
    try await base.status(at: resolve(path))
  }

  func children(of path: VFSPath) async throws -> [VFSDirectoryEntry] {
    try await base.children(of: resolve(path))
  }

  func readData(at path: VFSPath) async throws -> Data {
    try await base.readData(at: resolve(path))
  }

  func writeData(_ data: Data, at path: VFSPath, append: Bool) async throws {
    try await base.writeData(data, at: resolve(path), append: append)
  }

  func createFile(at path: VFSPath, data: Data) async throws {
    try await base.createFile(at: resolve(path), data: data)
  }

  func createDirectory(at path: VFSPath, intermediates: Bool) async throws {
    try await base.createDirectory(at: resolve(path), intermediates: intermediates)
  }

  func remove(at path: VFSPath, recursive: Bool) async throws {
    try await base.remove(at: resolve(path), recursive: recursive)
  }

  func move(from source: VFSPath, to destination: VFSPath) async throws {
    try await base.move(from: resolve(source), to: resolve(destination))
  }

  func copy(from source: VFSPath, to destination: VFSPath) async throws {
    try await base.copy(from: resolve(source), to: resolve(destination))
  }

  func open(at path: VFSPath, mode: VFSOpenMode) async throws -> any VFSFileHandle {
    try await base.open(at: resolve(path), mode: mode)
  }
}
