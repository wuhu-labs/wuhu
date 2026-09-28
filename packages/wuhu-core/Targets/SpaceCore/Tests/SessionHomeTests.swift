import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct SessionHomeTests {
  private func tree(_ space: Space) async throws -> (agent: SessionID, task: SessionID, leaf: SessionID) {
    let store = space.sessions
    let agent = try await store.createSession(group: .shared, title: "agent", kind: .agent, createdBy: "morgan", model: .test)
    let task = try await store.createSession(
      group: .shared,
      title: "task", kind: .task, parent: agent, createdBy: agent.rawValue, executor: .kernel(.test),
    )
    let leaf = try await store.createSession(
      group: .shared,
      title: "leaf", kind: .task, parent: task, createdBy: task.rawValue, executor: .kernel(.test),
    )
    return (agent, task, leaf)
  }

  @Test func resolutionReadsTheRootThenTheSessionsOwnHomeAndNoAncestor() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let (agent, task, leaf) = try await tree(space)
      _ = try await space.writeText("/AGENTS.md", "# Space\nroot rules")
      _ = try await space.writeText("\(SessionHome.path(of: agent))/AGENTS.md", "agent rules")
      _ = try await space.writeText("\(SessionHome.path(of: task))/AGENTS.md", "task rules")
      _ = try await space.writeText("\(SessionHome.path(of: leaf))/AGENTS.md", "leaf rules")

      let home = try await space.sessionHome(leaf)
      #expect(home.path == "/_/sessions/\(leaf.rawValue)")
      #expect(home.chain == ["/AGENTS.md", "/_/sessions/\(leaf.rawValue)/AGENTS.md"])
      #expect(home.sections.map(\.text) == ["# Space\nroot rules", "leaf rules"])

      #expect(home.groupRendered == "from /AGENTS.md:\n\n# Space\nroot rules")
      let rendered = home.rendered
      #expect(!rendered.contains("root rules"), "the space's part renders apart from the session's")
      #expect(rendered.contains("from /_/sessions/\(leaf.rawValue)/AGENTS.md:\n\nleaf rules"))
      #expect(!rendered.contains(agent.rawValue) && !rendered.contains(task.rawValue))
      #expect(!rendered.contains("agent rules") && !rendered.contains("task rules"))
      #expect(rendered.hasPrefix("Your home in the space is /_/sessions/\(leaf.rawValue)/."))

      let agentHome = try await space.sessionHome(agent)
      #expect(agentHome.chain == ["/AGENTS.md", "/_/sessions/\(agent.rawValue)/AGENTS.md"])
    }
  }

  @Test func anEmptySpaceResolvesToTheHomePreambleOnly() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let (agent, _, _) = try await tree(space)
      let home = try await space.sessionHome(agent)
      #expect(home.sections.isEmpty)
      #expect(home.skills.isEmpty)
      #expect(home.groupRendered.isEmpty)
      #expect(!home.rendered.contains("from /"))
      #expect(!home.rendered.contains("skills (call read"))
    }
  }

  @Test func skillsListFromTheRootAndTheOwnHomeWithDescriptions() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let (agent, _, leaf) = try await tree(space)
      _ = try await space.writeText(
        "/.agents/skills/review/SKILL.md",
        "---\nname: review\ndescription: Review a PR the house way\n---\n# Review\nbody",
      )
      _ = try await space.writeText(
        "\(SessionHome.path(of: agent))/.agents/skills/deploy/SKILL.md",
        "# Deploy\n\nShip the thing to the fleet\n\nmore",
      )
      _ = try await space.writeText(
        "\(SessionHome.path(of: leaf))/.agents/skills/fix/SKILL.md",
        "# Fix\n\nMend the leaf",
      )
      _ = try await space.writeText("\(SessionHome.path(of: leaf))/.agents/skills/stray.md", "not a skill")
      _ = try await space.writeText("\(SessionHome.path(of: leaf))/.agents/skills/empty/notes.md", "no SKILL.md here")

      let home = try await space.sessionHome(leaf)
      #expect(home.skills == [
        .init(name: "review", description: "Review a PR the house way", path: "/.agents/skills/review/SKILL.md"),
        .init(name: "fix", description: "Mend the leaf", path: "/_/sessions/\(leaf.rawValue)/.agents/skills/fix/SKILL.md"),
      ], "the agent's deploy skill is its own, never its descendants'")
      #expect(home.rendered.contains(
        "Your skills (call read on the path before using one):\n- fix — Mend the leaf (/_/sessions/\(leaf.rawValue)/.agents/skills/fix/SKILL.md)",
      ))
      #expect(home.groupRendered == "Space skills (call read on the path before using one):\n- review — Review a PR the house way (/.agents/skills/review/SKILL.md)")
      #expect(try await space.sessionHome(agent).skills.map(\.name) == ["review", "deploy"])
    }
  }
}
