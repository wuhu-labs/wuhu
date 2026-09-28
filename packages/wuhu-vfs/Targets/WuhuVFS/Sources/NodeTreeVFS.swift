import Foundation

/// A ``VirtualFileSystem`` backed by a ``VFSNode`` tree.
///
/// This is the adapter for backends that genuinely want a node tree — the
/// journal SQLite space FS, disk, in-memory. It provides the path operations by
/// walking a root node, so the node-centric design stays an *implementation
/// detail* behind the path-addressed `VirtualFileSystem` contract. Remote/flat
/// backends conform `VirtualFileSystem` directly and never construct one of
/// these.
public struct NodeTreeVFS: VirtualFileSystem {
  public let root: any VFSNode

  public init(root: any VFSNode) {
    self.root = root
  }

  // MARK: - Path resolution

  /// Resolve a path to a node handle. Returns `nil` if the path is not
  /// structurally navigable. The returned node may not exist on the backing
  /// store — call `existingNode(at:)` or check `status` to verify.
  private func node(at path: VFSPath) async throws -> (any VFSNode)? {
    var node = root
    for name in path.components {
      guard let child = try await node.childNode(name.rawValue) else {
        return nil
      }
      node = child
    }
    return node
  }

  /// Resolve a path to a node that exists on the backing store.
  /// Returns `nil` if the path is not structurally navigable, or if the
  /// backing store reports the node as absent. A thrown error (permission,
  /// I/O) propagates — it is never collapsed into "absent".
  private func existingNode(at path: VFSPath) async throws -> (any VFSNode)? {
    guard let node = try await node(at: path) else { return nil }
    guard try await node.status != nil else { return nil }
    return node
  }

  private func requireNode(at path: VFSPath, kind: VFSNodeKind) async throws -> any VFSNode {
    guard let node = try await node(at: path), let status = try await node.status else {
      throw VFSError.notFound(path: path.absoluteFilePath)
    }
    guard status.kind == kind else {
      throw kind == .file
        ? VFSError.notAFile(path: path.absoluteFilePath)
        : VFSError.notADirectory(path: path.absoluteFilePath)
    }
    return node
  }

  private func requireDirectory(at path: VFSPath) async throws -> any VFSNode {
    try await requireNode(at: path, kind: .directory)
  }

  private func requireFile(at path: VFSPath) async throws -> any VFSNode {
    try await requireNode(at: path, kind: .file)
  }

  // MARK: - Inspection

  public func status(at path: VFSPath) async throws -> VFSNodeStatus? {
    guard let node = try await node(at: path) else { return nil }
    return try await node.status
  }

  public func children(of path: VFSPath) async throws -> [VFSDirectoryEntry] {
    let directory = try await requireDirectory(at: path)
    return try await directory.children()
  }

  // MARK: - Read

  public func readData(at path: VFSPath) async throws -> Data {
    guard let node = try await existingNode(at: path) else {
      throw VFSError.notFound(path: path.absoluteFilePath)
    }
    return try await node.readData()
  }

  // MARK: - Open

  public func open(at path: VFSPath, mode: VFSOpenMode) async throws -> any VFSFileHandle {
    let file = try await requireFile(at: path)
    return try await file.open(mode)
  }

  // MARK: - Write

  public func writeData(_ data: Data, at path: VFSPath, append: Bool) async throws {
    guard let name = path.lastComponent else {
      throw VFSError.notAFile(path: "/")
    }

    if let existing = try await existingNode(at: path) {
      guard let status = try await existing.status, status.kind == .file else {
        throw VFSError.notAFile(path: path.absoluteFilePath)
      }
      try await existing.writeData(data, append: append)
    } else {
      let parent = try await requireDirectory(at: path.parent ?? .root)
      _ = try await parent.createFile(name.rawValue, data: data)
    }
  }

  public func createFile(at path: VFSPath, data: Data) async throws {
    guard let name = path.lastComponent else {
      throw VFSError.notAFile(path: "/")
    }
    let parent = try await requireDirectory(at: path.parent ?? .root)
    _ = try await parent.createFile(name.rawValue, data: data)
  }

  public func createDirectory(at path: VFSPath, intermediates: Bool) async throws {
    guard let name = path.lastComponent else {
      throw VFSError.notADirectory(path: "/")
    }

    if intermediates {
      var node = root
      for component in path.components {
        if let child = try await node.childNode(component.rawValue),
           let status = try await child.status
        {
          guard status.kind == .directory else {
            throw VFSError.notADirectory(path: path.absoluteFilePath)
          }
          node = child
        } else {
          node = try await node.createDirectory(component.rawValue)
        }
      }
    } else {
      let parent = try await requireDirectory(at: path.parent ?? .root)
      _ = try await parent.createDirectory(name.rawValue)
    }
  }

  // MARK: - Move / Copy

  public func move(from sourcePath: VFSPath, to destPath: VFSPath) async throws {
    guard let destName = destPath.lastComponent else {
      throw VFSError.notAFile(path: destPath.absoluteFilePath)
    }
    guard let sourceNode = try await existingNode(at: sourcePath) else {
      throw VFSError.notFound(path: sourcePath.absoluteFilePath)
    }
    let destParent = try await requireDirectory(at: destPath.parent ?? .root)

    // Try fast path first
    if try await destParent.rename(sourceNode, as: destName.rawValue) {
      // Rename may be a copy on some backends (e.g. InMemoryVFSNode);
      // always clean up the source. Best-effort since some backends
      // (e.g. DiskVFSNode) already moved the source.
      try? await remove(at: sourcePath, recursive: true)
      return
    }

    // Fallback: copy + delete
    try await copy(from: sourcePath, to: destPath)
    try await remove(at: sourcePath, recursive: true)
  }

  public func copy(from sourcePath: VFSPath, to destPath: VFSPath) async throws {
    guard let destName = destPath.lastComponent else {
      throw VFSError.notAFile(path: destPath.absoluteFilePath)
    }
    guard let sourceNode = try await existingNode(at: sourcePath) else {
      throw VFSError.notFound(path: sourcePath.absoluteFilePath)
    }
    let destParent = try await requireDirectory(at: destPath.parent ?? .root)

    // Try fast path first
    if try await destParent.copy(sourceNode, as: destName.rawValue) {
      return
    }

    try await copyNode(sourceNode, as: destName.rawValue, into: destParent)
  }

  private func copyNode(_ source: any VFSNode, as name: String, into destination: any VFSNode) async throws {
    guard let status = try await source.status else {
      throw VFSNodeError.notFound
    }
    switch status.kind {
    case .file:
      let data = try await source.readData()
      _ = try await destination.createFile(name, data: data)

    case .directory:
      let newDirectory = try await destination.createDirectory(name)
      for entry in try await source.children() {
        guard let child = try await source.childNode(entry.name) else {
          throw VFSNodeError.notFound
        }
        try await copyNode(child, as: entry.name, into: newDirectory)
      }
    }
  }

  // MARK: - Removal

  public func remove(at path: VFSPath, recursive: Bool) async throws {
    guard let node = try await existingNode(at: path) else {
      throw VFSError.notFound(path: path.absoluteFilePath)
    }
    try await node.remove(recursive: recursive)
  }
}
