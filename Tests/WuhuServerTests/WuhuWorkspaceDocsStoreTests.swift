import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuServer

struct WuhuWorkspaceDocsStoreTests {
  @Test func listDocsFindsMarkdownAndParsesFrontmatter() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WuhuWorkspaceDocsStore(dataRoot: root)
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
    tags:
      - docs
      - workspace
    ---
    # Hello
    """

    try issue.write(to: issuePath, atomically: true, encoding: .utf8)
    try "Just a note\n".write(to: notePath, atomically: true, encoding: .utf8)

    let docs = try store.listDocs()
    #expect(docs.map(\.path) == ["issues/0020.md", "note.md"])

    let issueDoc = try #require(docs.first(where: { $0.path == "issues/0020.md" }))
    #expect(issueDoc.frontmatter["status"]?.stringValue == "open")
    #expect(issueDoc.frontmatter["assignee"]?.stringValue == "alice")
    #expect(issueDoc.frontmatter["tags"]?.array?.compactMap(\.stringValue) == ["docs", "workspace"])
  }

  @Test func readDocReturnsBodyWithoutFrontmatter() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WuhuWorkspaceDocsStore(dataRoot: root)
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

    let doc = try store.readDoc(relativePath: "issues/x.md")
    #expect(doc.frontmatter["status"]?.stringValue == "open")
    #expect(doc.body.contains("Body line 1"))
    #expect(!doc.body.contains("status: open"))
  }

  @Test func readDocRejectsTraversal() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("wuhu-workspace-docs-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WuhuWorkspaceDocsStore(dataRoot: root)
    try store.ensureDefaultDirectories()

    #expect(throws: WuhuWorkspaceDocsStoreError.self) {
      _ = try store.readDoc(relativePath: "../secrets.md")
    }
  }
}
