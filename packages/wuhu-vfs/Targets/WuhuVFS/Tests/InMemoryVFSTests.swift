import Foundation
import Testing
import WuhuVFS

struct InMemoryVFSTests {
  @Test func `creates reads appends and lists files`() async throws {
    let filesystem = NodeTreeVFS(root: InMemoryVFSNode())

    try await filesystem.createDirectory(at: try path(["docs"]), intermediates: false)
    try await filesystem.writeText("hello", at: try path(["docs", "note.txt"]), append: false)
    try await filesystem.writeText(" world", at: try path(["docs", "note.txt"]), append: true)

    #expect(try await filesystem.readText(at: try path(["docs", "note.txt"])) == "hello world")
    #expect(try await filesystem.children(of: try path(["docs"])) == [
      VFSDirectoryEntry(name: "note.txt", kind: .file),
    ])
    #expect(try await filesystem.status(at: try path(["docs", "note.txt"]))?.kind == .file)
  }

  @Test func `moves directories without losing nested children`() async throws {
    let filesystem = NodeTreeVFS(root: InMemoryVFSNode())

    try await filesystem.createDirectory(at: try path(["source", "nested"]), intermediates: true)
    try await filesystem.writeText("payload", at: try path(["source", "nested", "file.txt"]), append: false)
    try await filesystem.move(from: try path(["source"]), to: try path(["destination"]))

    #expect(try await filesystem.status(at: try path(["source"])) == nil)
    #expect(try await filesystem.readText(at: try path(["destination", "nested", "file.txt"])) == "payload")
  }

  @Test func `copies directories between independent trees`() async throws {
    let sourceRoot = InMemoryVFSNode()
    let source = NodeTreeVFS(root: sourceRoot)
    let destination = NodeTreeVFS(root: InMemoryVFSNode())

    try await source.createDirectory(at: try path(["source", "nested"]), intermediates: true)
    try await source.writeText("payload", at: try path(["source", "nested", "file.txt"]), append: false)

    let sourceNode = try #require(try await sourceRoot.childNode("source"))
    _ = try await destination.root.copy(sourceNode, as: "copied")

    #expect(try await destination.readText(at: try path(["copied", "nested", "file.txt"])) == "payload")
  }

  @Test func `rejects mutation when immutable`() async throws {
    let filesystem = NodeTreeVFS(root: InMemoryVFSNode(isMutable: false))

    await #expect(throws: VFSNodeError.immutable) {
      try await filesystem.writeText("nope", at: try path(["file.txt"]), append: false)
    }
  }
}
