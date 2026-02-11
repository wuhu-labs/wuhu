import Foundation
import Testing
import WuhuCore

struct WorkspaceManagerTests {
  @Test func materializeFolderTemplateWorkspaceCopiesAndRunsStartupScript() async throws {
    let fm = FileManager.default

    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-workspace-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    let template = base.appendingPathComponent("template", isDirectory: true)
    let workspaces = base.appendingPathComponent("workspaces", isDirectory: true)

    try fm.createDirectory(at: template, withIntermediateDirectories: true)

    try "hello\n".write(to: template.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

    let script = """
    echo started > started.txt
    """
    try script.write(to: template.appendingPathComponent("startup.sh"), atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(at: base) }

    let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
      sessionID: "sess-1",
      templatePath: template.path,
      startupScript: "startup.sh",
      workspacesPath: workspaces.path,
    )

    #expect(workspacePath != template.path)
    #expect(fm.fileExists(atPath: URL(fileURLWithPath: workspacePath).appendingPathComponent("README.txt").path))

    let markerPath = URL(fileURLWithPath: workspacePath).appendingPathComponent("started.txt").path
    #expect(fm.fileExists(atPath: markerPath))
    #expect((try? String(contentsOfFile: markerPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "started")
  }
}
