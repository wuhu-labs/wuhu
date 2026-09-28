import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct SessionTemplateTests {
  @Test func templatesListFromTheirManifests() async throws {
    let space = try makeSpace()
    _ = try await space.writeText(
      "/templates/night/template.json",
      #"{"kind":"agent","description":"night shift","provider":"p","model":"m","effort":"low","tags":["n"]}"#,
    )
    _ = try await space.writeText("/templates/bare/template.json", "{}")
    _ = try await space.writeText("/templates/no-manifest/AGENTS.md", "not a template")
    _ = try await space.writeText("/templates/task.md", "a document template, not a session one")

    let listed = try await space.sessionTemplates(in: .shared)
    #expect(listed.map(\.name) == ["bare", "night"])
    let night = try await space.sessionTemplate(named: "night", in: .shared)
    #expect(night.kind == .agent)
    #expect(night.description == "night shift")
    #expect(night.params == SessionCreationParams(provider: "p", model: "m", effort: "low", tags: ["n"]))
    let bare = try await space.sessionTemplate(named: "bare", in: .shared)
    #expect(bare.kind == nil && bare.description == nil && bare.params == SessionCreationParams())

    await #expect(throws: ExecutorSpecError.self) { _ = try await space.sessionTemplate(named: "no-manifest", in: .shared) }
    await #expect(throws: ExecutorSpecError.self) { _ = try await space.sessionTemplate(named: "Night", in: .shared) }
    _ = try await space.writeText("/templates/odd/template.json", #"{"kind":"daemon"}"#)
    await #expect(throws: ExecutorSpecError.self) { _ = try await space.sessionTemplate(named: "odd", in: .shared) }
    _ = try await space.writeText("/templates/loose/template.json", #"{"identity":"owner"}"#)
    await #expect(throws: ExecutorSpecError.self) { _ = try await space.sessionTemplate(named: "loose", in: .shared) }
  }

  @Test func applyingATemplateClonesEverythingButTheManifestIntoTheHome() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      _ = try await space.writeText("/templates/night/template.json", "{}")
      _ = try await space.writeText("/templates/night/AGENTS.md", "night rules")
      _ = try await space.writeText("/templates/night/.agents/skills/watch/SKILL.md", "# Watch\nKeep watch")
      _ = try await space.writeText("/templates/night/notes/deep/er.md", "nested")

      let session = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await space.applySessionTemplate(try await space.sessionTemplate(named: "night", in: .shared), to: session)

      let home = SessionHome.path(of: session)
      #expect(try await space.readText("\(home)/AGENTS.md") == "night rules")
      #expect(try await space.readText("\(home)/.agents/skills/watch/SKILL.md") == "# Watch\nKeep watch")
      #expect(try await space.readText("\(home)/notes/deep/er.md") == "nested")
      await #expect(throws: SpaceError.notFound("\(home)/template.json")) {
        _ = try await space.readText("\(home)/template.json")
      }

      let resolved = try await space.sessionHome(session)
      #expect(resolved.chain == ["\(home)/AGENTS.md"])
      #expect(resolved.skills.map(\.name) == ["watch"])
    }
  }
}
