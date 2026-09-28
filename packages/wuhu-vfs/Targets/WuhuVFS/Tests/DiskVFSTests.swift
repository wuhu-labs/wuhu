import Foundation
import Testing
import WuhuVFS

struct DiskVFSTests {
  @Test func `reads writes and removes disk-backed files`() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WuhuVFSTests-")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let filesystem = NodeTreeVFS(root: DiskVFSNode(path: rootURL.path, isMutable: true))

    try await filesystem.createDirectory(at: try path(["docs"]), intermediates: false)
    try await filesystem.writeText("hello", at: try path(["docs", "note.txt"]), append: false)
    try await filesystem.writeText(" world", at: try path(["docs", "note.txt"]), append: true)

    #expect(try await filesystem.readText(at: try path(["docs", "note.txt"])) == "hello world")
    #expect(try await filesystem.children(of: try path(["docs"])) == [
      VFSDirectoryEntry(name: "note.txt", kind: .file),
    ])

    try await filesystem.remove(at: try path(["docs"]), recursive: true)
    #expect(try await filesystem.status(at: try path(["docs"])) == nil)
  }
}
