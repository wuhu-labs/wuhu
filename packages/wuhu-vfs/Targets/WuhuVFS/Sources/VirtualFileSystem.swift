import Foundation

// MARK: - VFS node types

public enum VFSNodeKind: Sendable, Hashable {
  case file
  case directory
}

/// The kind and metadata of one node, gathered in a single fetch.
///
/// All fields that a backend can derive from one `stat`/row read live here, so
/// a caller never pays N round trips to read kind + size + mtime. The space
/// filesystem has no symlinks; a host disk symlink surfaces as whatever `stat`
/// reports (its target's kind), never as a distinct symlink kind.
public struct VFSNodeStatus: Sendable, Hashable {
  public var kind: VFSNodeKind
  public var size: Int64
  public var modifiedAt: Date
  public var accessedAt: Date
  public var createdAt: Date
  public var mode: UInt16
  public var uid: UInt32
  public var gid: UInt32

  public init(
    kind: VFSNodeKind,
    size: Int64 = 0,
    modifiedAt: Date = .distantPast,
    accessedAt: Date = .distantPast,
    createdAt: Date = .distantPast,
    mode: UInt16 = 0o644,
    uid: UInt32 = 0,
    gid: UInt32 = 0,
  ) {
    self.kind = kind
    self.size = size
    self.modifiedAt = modifiedAt
    self.accessedAt = accessedAt
    self.createdAt = createdAt
    self.mode = mode
    self.uid = uid
    self.gid = gid
  }
}

public struct VFSDirectoryEntry: Sendable, Hashable {
  public var name: String
  public var kind: VFSNodeKind

  public init(name: String, kind: VFSNodeKind) {
    self.name = name
    self.kind = kind
  }
}

// MARK: - VirtualFileSystem (protocol)

/// A path-addressed filesystem.
///
/// This is the contract tools, session infrastructure, and the URL resolver
/// consume. It is deliberately **path-based, not node-based**: a conforming
/// type owns its own navigation strategy and is NOT required to expose a node
/// tree. A node-tree backend (the journal SQLite space FS, disk, in-memory)
/// conforms via the generic ``NodeTreeVFS`` adapter; a remote/flat backend can
/// conform by answering the path operations directly, without materializing a
/// node per component round trip — which is the whole point of protocolizing
/// (`WuhuNewSpec.md:338-343`).
///
/// The space filesystem has no symlinks; this surface has no symlink, `lstat`,
/// `followSymlinks`, or `canonicalize` notion.
public protocol VirtualFileSystem: Sendable {
  /// The status of the node at `path`, or `nil` if it is definitively absent.
  /// A thrown error (permission, I/O) propagates and is never collapsed into
  /// "absent".
  func status(at path: VFSPath) async throws -> VFSNodeStatus?

  /// The entries of the directory at `path`. Throws if `path` is not a
  /// directory.
  func children(of path: VFSPath) async throws -> [VFSDirectoryEntry]

  /// The bytes of the file at `path`. Throws ``VFSError/notFound(path:)`` if
  /// absent.
  func readData(at path: VFSPath) async throws -> Data

  /// Write `data` to `path`, creating the file if absent (the parent directory
  /// must exist). `append` appends to existing content.
  func writeData(_ data: Data, at path: VFSPath, append: Bool) async throws

  /// Create a new file at `path` with `data`. The parent directory must exist.
  func createFile(at path: VFSPath, data: Data) async throws

  /// Create the directory at `path`. With `intermediates`, missing parent
  /// directories are created too.
  func createDirectory(at path: VFSPath, intermediates: Bool) async throws

  /// Remove the node at `path`. `recursive` removes a non-empty directory.
  func remove(at path: VFSPath, recursive: Bool) async throws

  /// Move the node at `from` to `to`.
  func move(from: VFSPath, to: VFSPath) async throws

  /// Copy the node at `from` to `to`.
  func copy(from: VFSPath, to: VFSPath) async throws

  /// Open a stateful handle to the file at `path`. The file must already exist.
  func open(at path: VFSPath, mode: VFSOpenMode) async throws -> any VFSFileHandle

  /// Find files under `root` matching the glob `pattern`, with a result cap
  /// (`matchLimit`), a scan cap (`entryLimit`), and an opaque resume cursor
  /// (`step`). A default tree-walk implementation is provided (``VFSSearch``);
  /// a remote backend overrides this to answer in one round trip
  /// (`WuhuNewSpec.md:344`).
  func find(
    root: VFSPath,
    pattern: String,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> FindPage

  /// Search file contents under `root` for `pattern` (regex or literal), with a
  /// match cap, a scan cap, and a resume cursor. A default tree-walk
  /// implementation is provided; a remote backend overrides it.
  func grep(
    root: VFSPath,
    pattern: String,
    options: GrepOptions,
    matchLimit: Int,
    entryLimit: Int,
    step: SearchCursor?,
  ) async throws -> GrepPage
}

// MARK: - Text extensions

public extension VirtualFileSystem {
  func readText(at path: VFSPath) async throws -> String {
    let data = try await readData(at: path)
    return String(decoding: data, as: UTF8.self)
  }

  func writeText(_ content: String, at path: VFSPath, append: Bool) async throws {
    guard let data = content.data(using: .utf8) else {
      throw VFSError.notAFile(path: path.absoluteFilePath)
    }
    try await writeData(data, at: path, append: append)
  }
}

// MARK: - Errors

public enum VFSError: Error, Sendable, CustomStringConvertible {
  case notFound(path: String)
  case notAFile(path: String)
  case notADirectory(path: String)
  case directoryNotEmpty(path: String)
  /// A staged write could not commit because the node changed under the handle.
  case conflict(path: String)

  public var description: String {
    switch self {
    case let .notFound(path): "File not found: \(path)"
    case let .notAFile(path): "Not a file: \(path)"
    case let .notADirectory(path): "Not a directory: \(path)"
    case let .directoryNotEmpty(path): "Directory not empty: \(path)"
    case let .conflict(path): "Write conflict: \(path)"
    }
  }
}
