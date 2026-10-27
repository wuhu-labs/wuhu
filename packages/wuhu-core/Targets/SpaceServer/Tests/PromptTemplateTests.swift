import DeterministicDependencies
import Foundation
import SessionDomain
import struct SpaceContract.PromptSession
import struct SpaceContract.SessionPromptOutput
import SpaceCore
@testable import SpaceServer
import Testing

private let model = ModelSpecifier(provider: "openai", model: "gpt-5.6-luna", effort: "medium")

private func latest(_ space: Space, _ id: SessionID) async throws -> String {
  try await renderPrompt(space: space, record: try await space.sessions.record(id), rev: try await space.currentRevision()).prompt
}

private func write(_ space: Space, _ path: String, _ text: String) async throws {
  _ = try await space.fs(.shared).write(path, Data(text.utf8), ifMatch: nil)
}

// The prompt is the system AGENTS.md, the group's, the system SESSION.md and
// the home's, each rendered as a template for the session.
@Suite(.deterministicDependencies) struct PromptTemplateTests {
  @Test func theSessionPartIsPinnedForAnAgentAndATask() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let agent = try await space.sessions.createSession(group: .shared, title: "desk", kind: .agent, createdBy: "owner", model: model)
      let task = try await space.sessions.createSession(
        group: .shared, title: "errand", kind: .task, parent: agent, createdBy: agent.rawValue, executor: .kernel(model),
      )
      let agentPrompt = try await sessionPrompt(space: space, session: agent).prompt
      let taskPrompt = try await sessionPrompt(space: space, session: task).prompt
      let marker = "\n\nfrom wuhu://system/SESSION.md:\n\n"
      let agentSplit = try #require(agentPrompt.range(of: marker))
      let taskSplit = try #require(taskPrompt.range(of: marker))
      #expect(agentPrompt.hasPrefix("from wuhu://system/AGENTS.md:\n\n# Working in a Wuhu space\n\nYou are a session inside a Wuhu space"))
      #expect(agentPrompt[..<agentSplit.lowerBound] == taskPrompt[..<taskSplit.lowerBound], "everything before SESSION.md is shared")
      #expect(agentPrompt[..<agentSplit.lowerBound].hasSuffix("- writing-style — Shape a reply for someone reading on a phone — outcome first, each layer shorter than the last, anything over ~15 lines becomes a file with a pointer; what a finished task, a proposal, a \"which one?\" and a document hand-over look like. (wuhu://system/skills/writing-style/SKILL.md)"))

      let home = "Your home in the space is /_/sessions/{id}/. Keep your AGENTS.md (standing instructions) and any notes you want to survive compaction there; a skill of yours is /_/sessions/{id}/.agents/skills/<name>/SKILL.md. Instructions resolve top-down — the system, your group's root, then yours; nothing comes from the session that created you. This prompt renders the space's files and your home's as of the start of this generation, and again after each compaction or Start over: an edit in between, yours included, reaches it only then."
      #expect(agentPrompt[agentSplit.upperBound...] == """
      You are an agent: a persistent identity with a box. Delegate with create_session(expects_reply: true, message) — that already opens the request, so do not call request on the new task until its final report lands. The final report wakes you; never poll for it, never arm a timer to wait for it. If the child shows no progress for 30 minutes while not waiting on anything, a stall notice wakes you instead: check on it. Acknowledge the asker, then stop. If the session that created you opens a request on you, answer it with report(request_id, kind: "final", content): only that closes it.

      Your session id is \(agent.rawValue) and your title is "desk". You run on model openai/gpt-5.6-luna.

      \(home.replacing("{id}", with: agent.rawValue))
      """)
      #expect(taskPrompt[taskSplit.upperBound...] == """
      You are a task: one asker, one brief. Your parent opened a request on you and is waiting. Answer it with report(request_id, kind: "final", content) — that is the only thing that closes it; assistant text reaches nobody, and send_message into the DM is not a report. The request id is the message-id on the request message's header. Send report(kind: "progress") whenever the shape of the work changes.

      You may end a run before the final report only if something is certain to wake you: a timer, an exec with a timeout, or a request you opened on a child with a deadline. An observation is not certain to fire — if you wait on one, arm a timer too.

      Your session id is \(task.rawValue) and your title is "errand". You run on model openai/gpt-5.6-luna.

      \(home.replacing("{id}", with: task.rawValue))
      """)
    }
  }

  @Test func theTemplateManualShowsItsTagsLiterally() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let agent = try await space.sessions.createSession(group: .shared, title: "a", kind: .agent, createdBy: "owner", model: model)
      let prompt = try await sessionPrompt(space: space, session: agent).prompt
      #expect(prompt.contains(#"""
      ## Prompt templates

      Every AGENTS.md (system, group, home, machine notes, repository) renders as a logic-less Mustache template for the session reading it, with no HTML escaping; `read` always returns the raw file. A frontmatter is dropped from the rendering. The system prompt renders once per generation, at its start and after each compaction or Start over, so a rename or a model switch shows from the next generation; a machine's or repository's renders with its notice.

      - `session` holds `id`, `title`, `task` and `agent` (booleans), `model`, `tags` (a map, so `{{#session.tags.review}}…{{/session.tags.review}}`) and `home`.
      - `{{> /path}}` includes a space file as the session, at the prompt's revision; `{{> path}}` resolves from the including file's folder, wherever that file lives (the space, a machine, a repository), so a repository's AGENTS.md includes its own files. Partials nest at most 8 deep; a cycle renders the error line.
      - Frontmatter `wuhu_queries: {desk: SELECT …}` runs each query as the session at render time and binds its rows: `{{#desk}}{{title}}{{/desk}}`, `{{^desk}}none{{/desk}}`.
      - A syntax error, a missing partial or a failing query renders one `(template error in <path>: …)` line in its place; the prompt still renders.
      - A set-delimiter tag such as `{{=[[ ]]=}}` makes `[[` and `]]` the tag markers until the next one, so a file can show tags literally, as this section does.

      """#), "\(prompt)")
    }
  }

  // An upgrade after the prompt is stored, new system files included, never
  // re-renders it within the generation.
  @Test func aStoredPromptOutlivesAChangeOfTheSystemFiles() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let agent = try await space.sessions.createSession(group: .shared, title: "a", kind: .agent, createdBy: "owner", model: model)
      guard case let .pending(pending) = try await space.sessions.activatePrompt(agent) else { throw Unexpected() }
      let older = SessionPromptOutput(prompt: "rendered by an older binary", session: PromptSession(try await space.sessions.record(agent)))
      _ = try await space.sessions.storePrompt(agent, for: pending, older)
      #expect(try await sessionPrompt(space: space, session: agent) == older)
    }
  }

  @Test func partialsQueriesAndCyclesRenderAsTheSession() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let reviewer = try await space.sessions.createSession(
        group: .shared, title: "desk reviewer", kind: .agent, tags: ["review"], createdBy: "owner", model: model,
      )
      let task = try await space.sessions.createSession(
        group: .shared, title: "desk errand", kind: .task, parent: reviewer, createdBy: reviewer.rawValue, executor: .kernel(model),
      )
      try await write(space, "/AGENTS.md", """
      ---
      title: Space manual
      wuhu_queries:
        desk: SELECT title FROM sessions WHERE title LIKE 'desk%' ORDER BY title
        nobody: SELECT title FROM sessions WHERE title = 'nobody'
        broken: SELECT nope FROM nowhere
      ---
      {{#session.task}}Tasks report.{{/session.task}}{{#session.agent}}Agents delegate.{{/session.agent}}
      {{#session.tags.review}}
      Reviewers read diffs.
      {{/session.tags.review}}
      {{> /shared/rules.md}}
      {{#desk}}
      - {{title}}
      {{/desk}}
      {{^nobody}}
      Nobody is here.
      {{/nobody}}
      {{#broken}}x{{/broken}}
      {{> /shared/missing.md}}
      {{> shared/loop-a.md}}
      end
      """)
      try await write(space, "/shared/rules.md", "Rules for {{session.title}}.\n{{> nested.md}}")
      try await write(space, "/shared/loop-a.md", "a\n{{> loop-b.md}}\n")
      try await write(space, "/shared/loop-b.md", "b\n{{> /shared/loop-a.md}}\n")
      try await write(space, "/shared/nested.md", "Nested in {{session.home}}.\n")
      try await write(space, "\(SessionHome.path(of: task))/AGENTS.md", "{{#open}}never closed")

      let reviewed = try await latest(space, reviewer)
      #expect(reviewed.contains("""
      from /AGENTS.md:

      Agents delegate.
      Reviewers read diffs.
      Rules for desk reviewer.
      Nested in /_/sessions/\(reviewer.rawValue).
      - desk errand
      - desk reviewer
      Nobody is here.
      (template error in /AGENTS.md: query broken: 
      """), "\(reviewed)")
      #expect(reviewed.contains("(template error in /AGENTS.md: partial /shared/missing.md: "))
      #expect(reviewed.contains("\na\nb\n(template error in /shared/loop-b.md: partial /shared/loop-a.md includes itself through /shared/loop-b.md)\nend\n\nfrom wuhu://system/SESSION.md:"), "\(reviewed)")
      #expect(!reviewed.contains("Space manual"), "the frontmatter is not rendered")

      let errand = try await latest(space, task)
      #expect(errand.contains("from /AGENTS.md:\n\nTasks report.\nRules for desk errand."))
      #expect(!errand.contains("Reviewers read diffs."))
      #expect(errand.contains("from /_/sessions/\(task.rawValue)/AGENTS.md:\n\n(template error in /_/sessions/\(task.rawValue)/AGENTS.md: "))
      #expect(String(decoding: try await space.fs(.shared).read("/AGENTS.md").1, as: UTF8.self).contains("{{#desk}}"), "the file itself stays raw")
    }
  }

  @Test func skillsAreFilteredByWuhuWhenBeforeTheNearerNameHidesTheFarther() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let agent = try await space.sessions.createSession(group: .shared, title: "a", kind: .agent, createdBy: "owner", model: model)
      let home = SessionHome.path(of: agent)
      try await write(space, "/.agents/skills/image/SKILL.md", "---\ndescription: The house image style.\n---\n")
      try await write(space, "/.agents/skills/monitor/SKILL.md", "---\ndescription: Ops monitoring.\nwuhu_when: {tags: [ops]}\n---\n")
      try await write(space, "/.agents/skills/review/SKILL.md", "---\ndescription: Review the house way.\n---\n")
      try await write(space, "/.agents/skills/codex/SKILL.md", "---\ndescription: For Codex.\nwuhu_when:\n  model: [codex/*, openai/gpt-5.6-*]\n  kind: agent\n---\n")
      try await write(space, "/.agents/skills/odd/SKILL.md", "---\ndescription: Odd.\nwuhu_when: {color: blue}\n---\n")
      try await write(space, "\(home)/.agents/skills/review/SKILL.md", "---\ndescription: My review.\nwuhu_when: {kind: task}\n---\n")

      let prompt = try await latest(space, agent)
      #expect(!prompt.contains("(wuhu://system/skills/image/SKILL.md)"), "the space's image hides the system's")
      #expect(prompt.contains("- image — The house image style. (/.agents/skills/image/SKILL.md)"))
      #expect(prompt.contains("(wuhu://system/skills/monitor/SKILL.md)"), "a filtered-out nearer skill lets the farther one show")
      #expect(!prompt.contains("Ops monitoring."))
      #expect(prompt.contains("- review — Review the house way. (/.agents/skills/review/SKILL.md)"))
      #expect(!prompt.contains("My review."))
      #expect(prompt.contains("- codex — For Codex. (/.agents/skills/codex/SKILL.md)"))
      #expect(prompt.contains("- odd — Odd. (/.agents/skills/odd/SKILL.md) (wuhu_when error: wuhu_when has no key color)"))
      #expect(!prompt.contains("Your skills"))
    }
  }
}

private struct Unexpected: Error {}
