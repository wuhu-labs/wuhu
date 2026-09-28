import Foundation
import Testing
import WuhuVFS

/// Regression tests for the status/merged-metadata contract, covering the bugs
/// that motivated the rework. There is no symlink kind: a host disk symlink is
/// `stat`-followed to its target (or `notFound` if dangling).
struct VFSContractRegressionTests {
  private func diskRoot() throws -> (any VirtualFileSystem, URL) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WuhuVFSContract-")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return (NodeTreeVFS(root: DiskVFSNode(path: rootURL.path, isMutable: true)), rootURL)
  }

  @Test func `host disk symlink stats as its target kind, never as a symlink`() async throws {
    let (fs, rootURL) = try diskRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try await fs.writeText("payload", at: try path(["target.txt"]), append: false)
    try FileManager.default.createSymbolicLink(
      atPath: rootURL.appendingPathComponent("link").path,
      withDestinationPath: "target.txt",
    )

    // `stat` follows the link: it reports the target's file kind.
    let status = try #require(try await fs.status(at: try path(["link"])))
    #expect(status.kind == .file)

    // Listing reports the link as its target kind too.
    let entries = try await fs.children(of: .root)
    #expect(entries.contains(VFSDirectoryEntry(name: "link", kind: .file)))

    // Reading through the link yields the target bytes.
    #expect(try await fs.readText(at: try path(["link"])) == "payload")
  }

  @Test func `dangling host disk symlink is absent`() async throws {
    let (fs, rootURL) = try diskRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try FileManager.default.createSymbolicLink(
      atPath: rootURL.appendingPathComponent("dangling").path,
      withDestinationPath: "nowhere.txt",
    )

    // A dangling symlink `stat`s to `notFound`: we do not model it.
    #expect(try await fs.status(at: try path(["dangling"])) == nil)
  }

  @Test func `empty directory removes without recursive; non-empty requires it`() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    try await fs.createDirectory(at: try path(["empty"]), intermediates: false)
    try await fs.createDirectory(at: try path(["full"]), intermediates: false)
    try await fs.writeText("x", at: try path(["full", "f"]), append: false)

    try await fs.remove(at: try path(["empty"]), recursive: false)
    #expect(try await fs.status(at: try path(["empty"])) == nil)

    await #expect(throws: (any Error).self) {
      try await fs.remove(at: try path(["full"]), recursive: false)
    }
  }

  @Test func `passthrough file handle reads and writes through the node`() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    try await fs.writeText("one", at: try path(["f.txt"]), append: false)

    let handle = try await fs.open(at: try path(["f.txt"]), mode: .write)
    #expect(try await handle.readData() == Data("one".utf8))
    try await handle.writeData(Data("two".utf8), append: false)
    #expect(try await handle.close() == nil)

    #expect(try await fs.readText(at: try path(["f.txt"])) == "two")
  }

  @Test func `status returns nil for absent paths and merged metadata for files`() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    try await fs.writeText("hello", at: try path(["f.txt"]), append: false)

    #expect(try await fs.status(at: try path(["missing"])) == nil)
    let status = try #require(try await fs.status(at: try path(["f.txt"])))
    #expect(status.kind == .file)
    #expect(status.size == 5)
  }
}
