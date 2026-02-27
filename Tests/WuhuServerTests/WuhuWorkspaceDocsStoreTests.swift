import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuServer

struct WuhuWorkspaceDocsStoreTests {
  @Test func listDocsFindsMarkdownAndParsesFrontmatter() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WuhuWorkspaceDocsStore(dataRoot: root)
    try store.ensureDefaultDirectories()

    let issuePath = store.workspaceRoot
      .appendingPathComponent("issues", isDirectory: true)
      .appendingPathComponent("0020.md", isDirectory: false)
    let notePath = store.workspaceRoot
      .appendingPathComponent("note.md", isDirectory: false)

    let issue = """
    ---
    title: Workspace docs
    status: open
    assignee: alice
    ---
    # Hello
    """

    try issue.write(to: issuePath, atomically: true, encoding: .utf8)
    try "Just a note\n".write(to: notePath, atomically: true, encoding: .utf8)

    // Perform a scan so the engine picks up the files.
    try await store.scanner.scan(into: store.engine)

    let docs = try await store.listDocs()
    #expect(docs.map(\.path) == ["issues/0020.md", "note.md"])

    let issueDoc = try #require(docs.first(where: { $0.path == "issues/0020.md" }))
    #expect(issueDoc.frontmatter["status"]?.stringValue == "open")
    #expect(issueDoc.frontmatter["assignee"]?.stringValue == "alice")
    // The engine stores properties as flat [String: String]; array values are not preserved.
    #expect(issueDoc.frontmatter["kind"]?.stringValue == "issue")
  }

  @Test func readDocReturnsBodyWithoutFrontmatter() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WuhuWorkspaceDocsStore(dataRoot: root)
    try store.ensureDefaultDirectories()

    let path = store.workspaceRoot
      .appendingPathComponent("issues", isDirectory: true)
      .appendingPathComponent("x.md", isDirectory: false)
    let raw = """
    ---
    status: open
    ---
    Body line 1
    Body line 2
    """
    try raw.write(to: path, atomically: true, encoding: .utf8)

    // Perform a scan so the engine picks up the files.
    try await store.scanner.scan(into: store.engine)

    let doc = try await store.readDoc(relativePath: "issues/x.md")
    #expect(doc.frontmatter["status"]?.stringValue == "open")
    #expect(doc.body.contains("Body line 1"))
    #expect(!doc.body.contains("status: open"))
  }

  @Test func readDocRejectsTraversal() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WuhuWorkspaceDocsStore(dataRoot: root)
    try store.ensureDefaultDirectories()

    await #expect(throws: WuhuWorkspaceDocsStoreError.self) {
      _ = try await store.readDoc(relativePath: "../secrets.md")
    }
  }
}
