import Foundation
import Testing
import WuhuVFS

struct VFSPathComponentValidationTests {
  @Test func `in-memory node rejects invalid child names consistently`() async throws {
    try await ChildNameValidationContract.rejectsInvalidChildNames(InMemoryVFSNode())
  }

  @Test func `disk node rejects invalid child names consistently`() async throws {
    let root = try TemporaryDiskRoot()
    defer { root.remove() }

    try await ChildNameValidationContract.rejectsInvalidChildNames(root.node)
  }

  @Test func `in-memory node preserves valid child-name behavior`() async throws {
    try await ChildNameValidationContract.acceptsValidChildNames(InMemoryVFSNode())
  }

  @Test func `disk node preserves valid child-name behavior`() async throws {
    let root = try TemporaryDiskRoot()
    defer { root.remove() }

    try await ChildNameValidationContract.acceptsValidChildNames(root.node)
  }

  @Test func `disk root cannot be escaped through invalid child names`() async throws {
    let root = try TemporaryDiskRoot()
    defer { root.remove() }

    let escapedName = "escaped-\(UUID().uuidString).txt"
    let escapedURL = root.url.deletingLastPathComponent().appendingPathComponent(escapedName)
    defer { try? FileManager.default.removeItem(at: escapedURL) }

    await #expect(throws: VFSNodeError.forbidden) {
      _ = try await root.node.childNode("../\(escapedName)")
    }
    await #expect(throws: VFSNodeError.forbidden) {
      _ = try await root.node.createFile("../\(escapedName)", data: Data("escape".utf8))
    }

    let filesystem = NodeTreeVFS(root: root.node)
    await #expect(throws: VFSPathError.invalidComponent("..")) {
      try await filesystem.writeText("escape", at: try path(["..", escapedName]), append: false)
    }
    await #expect(throws: VFSPathError.invalidComponent("..")) {
      try await filesystem.createDirectory(at: try path(["safe", ".."]), intermediates: true)
    }

    #expect(!FileManager.default.fileExists(atPath: escapedURL.path))
    #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("safe").path))
  }
}

private enum ChildNameValidationContract {
  static let invalidNames = [
    "",
    ".",
    "..",
    "nested/file.txt",
    "nested\\file.txt",
  ]

  static func rejectsInvalidChildNames(_ root: any VFSNode) async throws {
    let source = try await root.createFile("source.txt", data: Data("source".utf8))

    let filesystem = NodeTreeVFS(root: root)

    for name in invalidNames {
      await #expect(throws: VFSNodeError.forbidden) {
        _ = try await root.childNode(name)
      }
      await #expect(throws: VFSNodeError.forbidden) {
        _ = try await root.createFile(name, data: Data("invalid".utf8))
      }
      await #expect(throws: VFSNodeError.forbidden) {
        _ = try await root.createDirectory(name)
      }
      await #expect(throws: VFSNodeError.forbidden) {
        _ = try await root.rename(source, as: name)
      }
      await #expect(throws: VFSNodeError.forbidden) {
        _ = try await root.copy(source, as: name)
      }
      await #expect(throws: VFSPathError.invalidComponent(name)) {
        try await filesystem.createFile(at: try path([name]), data: Data("invalid".utf8))
      }
      await #expect(throws: VFSPathError.invalidComponent(name)) {
        try await filesystem.createDirectory(at: try path(["safe", name]), intermediates: true)
      }
      await #expect(throws: VFSPathError.invalidComponent(name)) {
        try await filesystem.move(from: try path(["source.txt"]), to: try path([name]))
      }
      await #expect(throws: VFSPathError.invalidComponent(name)) {
        try await filesystem.copy(from: try path(["source.txt"]), to: try path([name]))
      }
    }
  }

  static func acceptsValidChildNames(_ root: any VFSNode) async throws {
    let directory = try await root.createDirectory("docs.v1")
    let file = try await directory.createFile("note-final.txt", data: Data("hello".utf8))
    #expect(try await file.readData() == Data("hello".utf8))

    #expect(try await root.copy(directory, as: "docs-copy"))
    #expect(try await root.rename(file, as: "renamed note.txt"))
  }
}

private struct TemporaryDiskRoot {
  let url: URL
  let node: DiskVFSNode

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("WuhuVFSPathComponentTests-")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    node = DiskVFSNode(path: url.path, isMutable: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
