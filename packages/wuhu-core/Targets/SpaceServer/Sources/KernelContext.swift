import InferenceKit
import LoopCore
import class MainHub.Hub
import protocol MainHub.Main
import SessionDomain
import SessionTools
import struct SpaceContract.PromptSession
import struct SpaceContract.SessionPromptOutput
import SpaceCore
import SpaceTools
import SystemFiles

// The loop's: the models document as the session reads it from main.
func budgetResolver(owner: any Main, executor: ToolExecutor) -> @Sendable (SessionID) async -> ContextBudget {
  { id in
    guard let record = try? await owner.record(id),
          let specifier = await activeModelSpecifier(record, owner: owner),
          let catalog = try? await executor.catalog(id, includeGroups: false)
    else { return fallbackBudget }
    return contextBudget(specifier, catalog.document) ?? fallbackBudget
  }
}

// Main's own, for what it shows of a session's context: the settings group's models document.
func budgetResolver(owner: Hub) -> @Sendable (SessionID) async -> ContextBudget {
  { id in
    guard let record = try? await owner.record(id),
          let specifier = await activeModelSpecifier(record, owner: owner),
          let data = try? await owner.space.fs(.settings).read(ModelsDocument.spacePath).1,
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
func sessionPrompt(space: Space, session: SessionID) async throws -> SessionPromptOutput {
  switch try await space.sessions.activatePrompt(session) {
  case let .rendered(output):
    return output
  case let .pending(pending):
    let record = try await space.sessions.record(session)
    return try await space.sessions.storePrompt(session, for: pending, renderPrompt(space: space, record: record, rev: pending.rev))
  }
}

// One string, most shared first, so a provider's prefix cache can reuse it
// across sessions: the system AGENTS.md and skills, the group's AGENTS.md and
// skills, the system SESSION.md, then the home's AGENTS.md and skills. The
// space's files are read as the session at `rev`.
func renderPrompt(space: Space, record: SessionRecord, rev: Int) async throws -> SessionPromptOutput {
  let home = try await space.sessionHome(record.id, at: rev)
  let session = PromptSession(record)
  let context = SpaceToolContext(space: space, principal: Principal(actor: .session(record.id), group: record.group))
  let renderer = InstructionRenderer(session: session, rev: rev) { name, input throws(InstructionSourceFailure) in
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
  var parts: [String] = []
  for (layer, (listing, heading)) in zip(layers, zip(InstructionScope.listings(layers, for: session), headings)) {
    parts += await layer.rendered(listing: listing, under: heading, by: renderer)
  }
  return SessionPromptOutput(prompt: parts.joined(separator: "\n\n"), session: session)
}
