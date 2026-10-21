import Foundation
import SessionDomain
import struct SpaceContract.SessionContext
import SpaceCore

func sessionContext(
  _ record: SessionRecord,
  store: SessionStore,
  budget: @Sendable (SessionID) async -> ContextBudget,
) async -> SessionContext? {
  guard !record.executor.isRetired else { return nil }
  guard let transcript = try? await store.transcript(record.id) else { return nil }
  let budget = await budget(record.id)
  let maxTokens = budget.usableTokens
  let used = transcript.estimatedContextTokens(images: budget.images)
  return SessionContext(
    usedTokens: used,
    maxTokens: maxTokens,
    percentage: percentage(used: used, maxTokens: maxTokens),
    updatedAt: nil,
    source: .estimate,
  )
}

private func percentage(used: Int, maxTokens: Int) -> Double {
  guard maxTokens > 0 else { return 0 }
  return Double(used) / Double(maxTokens) * 100
}
