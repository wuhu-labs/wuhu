import Foundation
import Testing
import WuhuAPI
import WuhuCore

struct WuhuSkillsTests {
  @Test func loaderMergesUserAndProjectWithProjectWinning() throws {
    let home = try makeTempDir(prefix: "wuhu-home")
    let envRoot = try makeTempDir(prefix: "wuhu-env")

    let userSkillDir = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".wuhu/skills/format/SKILL.md")
    let projectSkillDir = URL(fileURLWithPath: envRoot, isDirectory: true)
      .appendingPathComponent(".wuhu/skills/format/SKILL.md")

    try FileManager.default.createDirectory(at: userSkillDir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
    try FileManager.default.createDirectory(at: projectSkillDir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

    try """
    ---
    name: format
    description: user version
    ---

    body
    """.write(to: userSkillDir, atomically: true, encoding: .utf8)

    try """
    ---
    name: format
    description: project version
    ---
    """.write(to: projectSkillDir, atomically: true, encoding: .utf8)

    let skills = WuhuSkillLoader.loadSkills(environmentRoot: envRoot, homeDirectory: URL(fileURLWithPath: home, isDirectory: true))
    #expect(skills.count == 1)
    #expect(skills.first?.name == "format")
    #expect(skills.first?.description == "project version")
    #expect(skills.first?.source == .project)
  }

  @Test func promptFormatterOmitsDisableModelInvocation() {
    let skills = [
      WuhuSkill(name: "a", description: "desc a", filePath: "/tmp/a/SKILL.md", source: .project, disableModelInvocation: false),
      WuhuSkill(name: "b", description: "desc b", filePath: "/tmp/b/SKILL.md", source: .project, disableModelInvocation: true),
    ]
    let text = WuhuSkillsPromptFormatter.formatForSystemPrompt(skills)
    #expect(text.contains("<available_skills>"))
    #expect(text.contains("<name>a</name>"))
    #expect(!text.contains("<name>b</name>"))
  }

  private func makeTempDir(prefix: String) throws -> String {
    let root = FileManager.default.temporaryDirectory
    let dir = root.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }
}
