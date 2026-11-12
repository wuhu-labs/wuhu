import SessionDomain
import struct SpaceContract.SessionContext
import SpaceCore

func sessionContext(
  _ record: SessionRecord,
  store: SessionStore,
  budget: @Sendable (SessionID) async -> ContextBudget,
) async throws -> SessionContext? {
  guard !record.executor.isRetired else { return nil }
  let lines = try await store.transcriptLines(record.id).map { try $0.line() }
  let budget = await budget(record.id)
  let maxTokens = budget.usableTokens
  let used = lines.estimatedContextTokens(images: budget.images)
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
