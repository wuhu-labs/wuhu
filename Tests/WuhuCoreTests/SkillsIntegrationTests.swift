import Foundation
import Testing
import WuhuAPI
import WuhuCore

struct SkillsIntegrationTests {
  @Test func createSessionLoadsSkillsIntoHeader() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-\(UUID().uuidString.lowercased())", isDirectory: true)
    let skillsDir = root.appendingPathComponent(".wuhu/skills/hello-skill", isDirectory: true)
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let skillFile = skillsDir.appendingPathComponent("SKILL.md")
    let text = """
    ---
    name: hello-skill
    description: A test skill.
    ---

    # Hello Skill
    """
    try text.write(to: skillFile, atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(at: root) }

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let env = WuhuEnvironment(name: "local", type: .local, path: root.path)

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environmentID: nil,
      environment: env,
    )

    let entries = try await store.getEntries(sessionID: sessionID)
    guard let headerEntry = entries.first(where: { if case .header = $0.payload { true } else { false } }),
          case let .header(header) = headerEntry.payload
    else {
      Issue.record("Expected header entry")
      return
    }

    #expect(header.systemPrompt.contains("<available_skills>"))
    #expect(header.systemPrompt.contains("hello-skill"))

    let skills = WuhuSkills.decodeFromHeaderMetadata(header.metadata)
    #expect(skills.count == 1)
    #expect(skills.first?.name == "hello-skill")
    #expect(skills.first?.description == "A test skill.")
    #expect(skills.first?.filePath.hasSuffix("/.wuhu/skills/hello-skill/SKILL.md") == true)
  }
}
