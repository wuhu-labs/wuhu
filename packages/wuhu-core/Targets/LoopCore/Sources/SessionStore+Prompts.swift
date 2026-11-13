#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import struct SessionDomain.TranscriptPreamble
import struct SpaceContract.PromptSession
import struct SpaceCore.PendingPrompt
import struct SpaceCore.Principal
import struct SpaceCore.PromptOpening
import enum SpaceCore.SessionPromptReference
import enum SpaceCore.SessionPromptState
import struct SpaceCore.SessionStore
import struct SpaceCore.SpaceCell
import struct SpaceCore.StoredPrompt
import enum WuhuAI.Tool

private enum PreparedPrompt {
  case existing(SessionPromptReference)
  case pending(PendingPrompt)
}

public extension SessionStore {
  func promptRevisions(_ id: SessionID) async throws -> [String: Int]? {
    try space.worker.cell(SessionCell.ID(id.rawValue)).promptRevisions()
  }

  func promptForInference(_ id: SessionID) async throws -> SessionPromptState {
    let address = SessionCell.ID(id.rawValue)
    let prepared = try space.worker.read { reader -> PreparedPrompt in
      let cell = reader.cell(address)
      if let reference = try cell.promptReference() { return .existing(reference) }
      let record = try cell.creationRecord()
      let principal = Principal(actor: .session(id), group: record.group)
      let spaceCell = reader.cell(SpaceCell.ID("space"))
      let revs = spaceCell.revisions(in: spaceCell.readable(by: principal).union([principal.group]))
      return .pending(try cell.pendingInferencePrompt(revs: revs))
    }
    switch prepared {
    case let .existing(reference): return try await promptState(reference)
    case let .pending(pending):
      space.worker.send(address).setInferencePrompt(pending)
      return .pending(pending)
    }
  }

  func storeInferencePrompt(_ id: SessionID, for pending: PendingPrompt, _ prompt: String, opening: PromptOpening? = nil, tools: [Tool], session: PromptSession) async throws -> StoredPrompt {
    precondition(opening == nil || pending.opening, "the generation keeps no room for an opening")
    let address = SessionCell.ID(id.rawValue)
    let reference = try space.worker.cell(address).inferencePromptWinner(for: pending)
    if let reference {
      guard case let .rendered(stored) = try await promptState(reference) else {
        preconditionFailure("a prompt winner is rendered")
      }
      return stored
    }
    let preamble = TranscriptPreamble(system: prompt, tools: tools)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let hash = try await stageBlob(Array(try encoder.encode(preamble)))
    space.worker.send(address).storeInferencePrompt(for: pending, rendered: hash, opening: opening, session: session)
    return StoredPrompt(rendered: hash, preamble: preamble, opening: [opening?.group, opening?.session].compactMap(\.self).filter { !$0.isEmpty }, session: session)
  }

  func invalidatePromptRevision(_ id: SessionID) async throws {
    _ = try space.worker.cell(SessionCell.ID(id.rawValue)).promptRevisions()
    space.worker.send(SessionCell.ID(id.rawValue)).invalidatePromptRevision()
  }

  private func promptState(_ reference: SessionPromptReference) async throws -> SessionPromptState {
    switch reference {
    case let .pending(pending): return .pending(pending)
    case let .rendered(hash, opening, session):
      let preamble = try JSONDecoder().decode(TranscriptPreamble.self, from: Data(try await space.blobBytes(hash)))
      return .rendered(StoredPrompt(rendered: hash, preamble: preamble, opening: opening, session: session))
    }
  }
}
