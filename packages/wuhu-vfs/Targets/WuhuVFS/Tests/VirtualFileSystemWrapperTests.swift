import Foundation
import Testing
import WuhuVFS

struct VirtualFileSystemWrapperTests {
  @Test func `read only filesystem forwards reads and rejects mutations`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["docs", "note.txt"]), data: Data("hello".utf8))
    let filesystem = NodeTreeVFS(root: root).readOnly()

    #expect(try await filesystem.children(of: try path(["docs"])) == [
      VFSDirectoryEntry(name: "note.txt", kind: .file),
    ])
    #expect(try await filesystem.readText(at: try path(["docs", "note.txt"])) == "hello")

    await #expect(throws: VFSNodeError.immutable) {
      try await filesystem.writeText("blocked", at: try path(["docs", "note.txt"]), append: false)
    }
    await #expect(throws: VFSNodeError.immutable) {
      try await filesystem.createDirectory(at: try path(["docs", "nested"]), intermediates: false)
    }
    await #expect(throws: VFSNodeError.immutable) {
      try await filesystem.remove(at: try path(["docs", "note.txt"]), recursive: false)
    }
  }

  @Test func `scoped filesystem exposes absolute path as root`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["Users", "dev", "Desktop", "note.txt"]), data: Data("desktop".utf8))
    try await root.seedFile(at: try path(["Users", "dev", "Documents", "draft.md"]), data: Data("draft".utf8))
    try await root.seedFile(at: try path(["Users", "other", "secret.txt"]), data: Data("secret".utf8))
    let filesystem = NodeTreeVFS(root: root).scoped(to: try path("/Users/dev"))

    #expect(try await filesystem.children(of: try path([])) == [
      VFSDirectoryEntry(name: "Desktop", kind: .directory),
      VFSDirectoryEntry(name: "Documents", kind: .directory),
    ])
    #expect(try await filesystem.readText(at: try path(["Desktop", "note.txt"])) == "desktop")
    await #expect(throws: VFSPathError.invalidComponent("..")) {
      _ = try await filesystem.status(at: try path(["..", "other", "secret.txt"]))
    }
  }

  @Test func `scoped filesystem writes through to scoped root`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedDirectory(at: try path(["Users", "dev"]))
    let filesystem = NodeTreeVFS(root: root).scoped(to: try path("/Users/dev"))

    try await filesystem.createDirectory(at: try path(["Documents"]), intermediates: false)
    try await filesystem.writeText("draft", at: try path(["Documents", "draft.md"]), append: false)

    let unscoped = NodeTreeVFS(root: root)
    #expect(try await unscoped.readText(at: try path(["Users", "dev", "Documents", "draft.md"])) == "draft")
  }

  /// The point of protocolizing: a backend that has NO node tree can conform
  /// `VirtualFileSystem` directly by answering path operations — which is how a
  /// remote machine will implement the surface (no per-component RPC). This flat
  /// in-memory conformer proves the contract is node-free, and that the
  /// `readOnly()`/`scoped(to:)` protocol wrappers compose over an arbitrary
  /// conformer, not just `NodeTreeVFS`.
  @Test func `a node-free filesystem conforms and composes with the wrappers`() async throws {
    let flat = FlatVFS(files: ["/a.txt": Data("alpha".utf8), "/dir/b.txt": Data("beta".utf8)])

    #expect(try await flat.readText(at: try path(["a.txt"])) == "alpha")
    #expect(try await flat.status(at: try path(["dir", "b.txt"]))?.kind == .file)
    #expect(try await flat.status(at: try path(["missing"])) == nil)

    // readOnly wrapper over a non-node-tree conformer.
    let readOnly = flat.readOnly()
    #expect(try await readOnly.readText(at: try path(["a.txt"])) == "alpha")
    await #expect(throws: VFSNodeError.immutable) {
      try await readOnly.writeText("x", at: try path(["a.txt"]), append: false)
    }

    // scoped wrapper over a non-node-tree conformer.
    let scoped = flat.scoped(to: try path("/dir"))
    #expect(try await scoped.readText(at: try path(["b.txt"])) == "beta")
  }
}

/// A flat, path-keyed `VirtualFileSystem` with no node tree — a stand-in for a
/// remote/flat backend. Read-only and minimal; enough to prove the protocol does
/// not require a node tree.
private struct FlatVFS: VirtualFileSystem {
  var files: [String: Data]

  func status(at path: VFSPath) async throws -> VFSNodeStatus? {
    let key = path.absoluteFilePath
    if files[key] != nil { return VFSNodeStatus(kind: .file) }
    // A directory exists if any file lives beneath it.
    let prefix = key == "/" ? "/" : key + "/"
    if files.keys.contains(where: { $0.hasPrefix(prefix) }) { return VFSNodeStatus(kind: .directory) }
    return nil
  }

  func children(of path: VFSPath) async throws -> [VFSDirectoryEntry] {
    let prefix = path.absoluteFilePath == "/" ? "/" : path.absoluteFilePath + "/"
    var names: Set<String> = []
    for key in files.keys where key.hasPrefix(prefix) {
      let tail = key.dropFirst(prefix.count)
      if let first = tail.split(separator: "/", maxSplits: 1).first { names.insert(String(first)) }
    }
    return names.sorted().map { VFSDirectoryEntry(name: $0, kind: files[prefix + $0] != nil ? .file : .directory) }
  }

  func readData(at path: VFSPath) async throws -> Data {
    guard let data = files[path.absoluteFilePath] else { throw VFSError.notFound(path: path.absoluteFilePath) }
    return data
  }

  func writeData(_: Data, at path: VFSPath, append _: Bool) async throws { throw VFSNodeError.immutable }
  func createFile(at path: VFSPath, data _: Data) async throws { throw VFSNodeError.immutable }
  func createDirectory(at path: VFSPath, intermediates _: Bool) async throws { throw VFSNodeError.immutable }
  func remove(at path: VFSPath, recursive _: Bool) async throws { throw VFSNodeError.immutable }
  func move(from _: VFSPath, to _: VFSPath) async throws { throw VFSNodeError.immutable }
  func copy(from _: VFSPath, to _: VFSPath) async throws { throw VFSNodeError.immutable }
  func open(at path: VFSPath, mode _: VFSOpenMode) async throws -> any VFSFileHandle { throw VFSNodeError.immutable }
}
