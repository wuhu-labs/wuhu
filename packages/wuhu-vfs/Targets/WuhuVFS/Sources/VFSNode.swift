import Foundation

/// Protocol for filesystem backend implementors.
///
/// `VFSNode` models a single node in a virtual filesystem tree — a file or
/// directory. Backends implement this protocol to provide storage (disk,
/// in-memory, SFTP, etc.). There is no symlink kind: the space filesystem has
/// no symlinks, and a host disk symlink surfaces as its `stat` target.
///
/// Navigation is structural: `childNode` returns a child handle cheaply
/// (`DiskVFSNode` just appends to the path) and does **not** verify existence.
/// `status` is the sole authority for existence, kind, and metadata.
///
/// `status` reports `nil` when the node is definitively absent and throws only
/// when existence could not be determined (permission, I/O, remote timeout).
///
/// Creation operations (`createFile`, `createDirectory`) live on the parent
/// directory node — call them on a directory to add children.
public protocol VFSNode: Sendable {
  // MARK: - Identity

  /// The kind and metadata of this node, or `nil` if it is definitively absent
  /// on the backing store. Throws only when existence could not be determined
  /// (e.g. permission denied, I/O error, remote timeout) — a thrown error must
  /// never be interpreted as "absent".
  var status: VFSNodeStatus? { get async throws }

  // MARK: - Navigation

  /// List direct children of this directory. Throws for non-directory nodes.
  func children() async throws -> [VFSDirectoryEntry]

  /// Return a child handle for the given single-component name, or `nil` if no
  /// such child exists structurally (e.g. no entry in an in-memory dictionary).
  /// This is NOT an existence check — call `status` on the returned node to
  /// verify.
  ///
  /// Throws `VFSNodeError.forbidden` for invalid child names.
  func childNode(_ name: String) async throws -> (any VFSNode)?

  // MARK: - Data

  /// Read the full binary content of this file. Throws for directories.
  func readData() async throws -> Data

  /// Write binary content to this file. Set `append: true` to append
  /// instead of overwriting. Throws for directories.
  func writeData(_ data: Data, append: Bool) async throws

  /// Open a stateful handle to this file's contents. The default forwards
  /// reads and writes straight through; backends with optimistic concurrency
  /// (e.g. a versioned store) override this to stage edits and reconcile them
  /// at ``VFSFileHandle/close()``.
  func open(_ mode: VFSOpenMode) async throws -> any VFSFileHandle

  // MARK: - Creation (on directory nodes)

  /// Create a new file child. Throws if the node is not a directory, if a
  /// child with this name already exists, or if the child name is invalid.
  func createFile(_ name: String, data: Data) async throws -> any VFSNode

  /// Create a new directory child. Throws if not a directory, if the name
  /// already exists, or if the child name is invalid.
  func createDirectory(_ name: String) async throws -> any VFSNode

  // MARK: - Removal

  /// Remove this node from its parent. Non-empty directories require
  /// `recursive: true`; an empty directory may be removed either way.
  func remove(recursive: Bool) async throws

  // MARK: - Fast-path move / copy

  /// Move `source` into this directory as `name`. Returns `true` if the
  /// backend handled the move natively (e.g. `rename(2)`, dictionary swap).
  /// Return `false` to request a copy+delete fallback from the caller.
  /// Throws `VFSNodeError.forbidden` if `name` is invalid.
  func rename(_ source: any VFSNode, as name: String) async throws -> Bool

  /// Copy `source` into this directory as `name`. Returns `true` if the
  /// backend handled the copy natively. Return `false` for fallback.
  /// Throws `VFSNodeError.forbidden` if `name` is invalid.
  func copy(_ source: any VFSNode, as name: String) async throws -> Bool
}

// MARK: - Default implementations

extension VFSNode {
  // Files throw from directory operations
  public func children() async throws -> [VFSDirectoryEntry] { throw VFSNodeError.notADirectory }
  public func childNode(_ name: String) async throws -> (any VFSNode)? {
    try VFSPathComponent.require(name)
    throw VFSNodeError.notADirectory
  }

  public func createFile(_ name: String, data: Data) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    throw VFSNodeError.notADirectory
  }

  public func createDirectory(_ name: String) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    throw VFSNodeError.notADirectory
  }

  // Directories throw from file operations
  public func readData() async throws -> Data { throw VFSNodeError.notAFile }
  public func writeData(_ data: Data, append: Bool) async throws { throw VFSNodeError.immutable }

  // Pass-through handle by default; staging backends override `open`.
  public func open(_ mode: VFSOpenMode) async throws -> any VFSFileHandle {
    PassthroughFileHandle(node: self)
  }

  // Removal defaults to immutable
  public func remove(recursive: Bool) async throws { throw VFSNodeError.immutable }

  // Fast-path operations default to "not supported"
  public func rename(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    return false
  }

  public func copy(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    return false
  }
}

// MARK: - Errors

public enum VFSNodeError: Error {
  case notAFile
  case notADirectory
  case notFound
  case immutable
  case forbidden
}

// MARK: - Node status convenience

extension VFSNodeStatus {
  /// A file status with default metadata. For backends that do not track
  /// per-node metadata; real backends populate the full struct from one fetch.
  public static func file(size: Int64 = 0) -> VFSNodeStatus {
    .init(kind: .file, size: size, mode: 0o644)
  }

  public static func directory() -> VFSNodeStatus {
    .init(kind: .directory, mode: 0o755)
  }
}
