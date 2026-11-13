import struct SpaceContract.PromptSession
import struct SpaceCore.PendingPrompt
import struct SpaceCore.PromptOpening
import enum SpaceCore.SessionPromptReference
import enum SpaceCore.SessionPrompts

extension SessionCell {
  func promptRevisions() throws -> [String: Int]? {
    try SessionPrompts.revisions(id.key, in: db)
  }

  func promptReference() throws -> SessionPromptReference? {
    try SessionPrompts.reference(id.key, in: db)
  }

  func pendingInferencePrompt(revs: [String: Int]) throws -> PendingPrompt {
    try SessionPrompts.pending(id.key, revs: revs, in: db)
  }

  func inferencePromptWinner(for pending: PendingPrompt) throws -> SessionPromptReference? {
    try SessionPrompts.winner(id.key, for: pending, in: db)
  }

  mutating func invalidatePrompt() throws {
    try SessionPrompts.invalidate(id.key, in: &db)
  }

  mutating func acceptPendingPrompt(_ pending: PendingPrompt) throws {
    try SessionPrompts.setIfAbsent(id.key, pending: pending, in: &db)
  }

  mutating func acceptPromptRendering(for pending: PendingPrompt, rendered: String, opening: PromptOpening?, session: PromptSession) throws {
    try SessionPrompts.store(id.key, for: pending, rendered: rendered, opening: opening, session: session, at: now(), in: &db)
  }
}
