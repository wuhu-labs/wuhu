import InferenceKit
import struct Instructions.InstructionRenderer
import struct Instructions.InstructionSourceFailure
import LoopCore
import func MainHub.groupModulePath
import class MainHub.Hub
import ModelProviders
import SessionDomain
import SessionTools
import struct SpaceContract.PromptSession
import enum SpaceContract.SessionToolExecutor
import SpaceCore
import SpaceTools
import SystemFiles

// The loop's: the models document as the session reads it from main.
func budgetResolver(store: SessionStore, executor: ToolExecutor) -> @Sendable (SessionID) async -> ContextBudget {
  { id in
    guard let record = try? await store.record(id),
          let specifier = await activeModelSpecifier(record, store: store),
          let catalog = try? await executor.catalog(id, includeGroups: false)
    else { return fallbackBudget }
    return contextBudget(specifier, catalog.document) ?? fallbackBudget
  }
}

// Main's own, for what it shows of a session's context: the settings group's models document.
func budgetResolver(space: Space) -> @Sendable (SessionID) async -> ContextBudget {
  { id in
    guard let record = try? await space.sessions.record(id),
          let specifier = await activeModelSpecifier(record, store: space.sessions),
          let data = try? await space.fs(.settings).read(ModelsDocument.spacePath).1,
          let document = try? ModelsDocument(json: data)
    else { return fallbackBudget }
    return contextBudget(specifier, document) ?? fallbackBudget
  }
}

private let fallbackBudget = ContextBudget(maxInput: 1 << 22, maxOutput: 0)

private func contextBudget(_ specifier: ModelSpecifier, _ document: ModelsDocument) -> ContextBudget? {
  guard let model = try? ProviderCatalog(document: document, credentials: .unavailable).validate(specifier),
        let provider = document.providers[specifier.provider]
  else { return nil }
  return model.budget(images: provider.images)
}

// The session's prompt for its generation: rendered by the first inference
// after the prompt revision moves, then the same stored bytes until it moves
// again, so nothing within a generation (a rename, a model switch) changes it.
func sessionPrompt(space: Space, session: SessionID) async throws -> StoredPrompt {
  switch try await space.sessions.promptForInference(session) {
  case let .rendered(stored):
    return stored
  case let .pending(pending):
    let record = try await space.sessions.record(session)
    let (prompt, rendered) = try await renderPrompt(space: space, record: record, revs: pending.revs)
    let tools = SessionToolExecutor.kernel.tools
    guard pending.opening else {
      return try await space.sessions.storeInferencePrompt(session, for: pending, prompt.filter { !$0.isEmpty }.joined(separator: "\n\n"), tools: tools, session: rendered)
    }
    let opening = PromptOpening(
      group: prompt[1].isEmpty ? "" : "<group-instructions>\n\(prompt[1])\n</group-instructions>",
      session: "<session-instructions>\n\(prompt[2])\n</session-instructions>",
    )
    return try await space.sessions.storeInferencePrompt(session, for: pending, prompt[0], opening: opening, tools: tools, session: rendered)
  }
}

// Three parts by who changes them, most shared first, so a provider's prefix
// cache can reuse each across sessions: the system AGENTS.md and skills (the
// binary's), the group's AGENTS.md and skills, then the system SESSION.md
// with the home's AGENTS.md and skills. The first is the system text and the
// other two open the generation as user-role lines; a generation opened
// before those lines existed gets the three joined as its system text. The
// space's files are read as the session at each group's frozen revision.
func renderPrompt(space: Space, record: SessionRecord, revs: [String: Int]) async throws -> (prompt: [String], session: PromptSession) {
  let home = try await space.sessionHome(record.id, at: revs)
  let session = PromptSession(record)
  let context = SpaceToolContext(space: space, principal: Principal(actor: .session(record.id), group: record.group))
  let renderer = InstructionRenderer(session: session, revision: { address throws(InstructionSourceFailure) in
    do {
      var group = record.group
      if let (named, _) = groupModulePath(address) {
        guard let resolved = try await space.resolveGroup(named.rawValue) else { throw SpaceError.notFound(address) }
        group = resolved
      }
      guard let rev = revs[group.rawValue] else { throw SpaceError.notFound(address) }
      return rev
    } catch { throw InstructionSourceFailure(String(describing: error)) }
  }) { name, input throws(InstructionSourceFailure) in
    let tool = SpaceToolbox.all.first { $0.name == name }!
    do throws(ToolRunError) {
      return try await tool.run(context, input: input)
    } catch {
      switch error {
      case let .undecodableInput(message), let .failed(_, message, _, _): throw InstructionSourceFailure(message)
      }
    }
  }
  let layers = [SystemFiles.instructions, home.groupLayer, SystemFiles.session, home.home]
  let headings = [SystemFiles.skillsHeading, home.groupSkillsHeading, "", "Your skills (call read on the path before using one):"]
  var parts: [[String]] = []
  for (layer, (listing, heading)) in zip(layers, zip(InstructionScope.listings(layers, for: session), headings)) {
    parts.append(await layer.rendered(listing: listing, under: heading, by: renderer))
  }
  return ([parts[0], parts[1], parts[2] + parts[3]].map { $0.joined(separator: "\n\n") }, session)
}
