import Foundation
import SessionDomain
import struct SpaceContract.SessionContext
import SpaceCore

func sessionContext(
  _ record: SessionRecord,
  store: SessionStore,
  budget: @Sendable (SessionID) async -> ContextBudget,
  claudeCodeTokens: @Sendable (SessionID) async -> Int?,
) async -> SessionContext? {
  switch record.executor {
  case .claudeCode:
    guard let used = await claudeCodeTokens(record.id) else { return nil }
    let maxTokens = await budget(record.id).usableTokens
    return SessionContext(
      usedTokens: used,
      maxTokens: maxTokens,
      percentage: percentage(used: used, maxTokens: maxTokens),
      updatedAt: nil,
      source: .reported,
    )
  case .kernel:
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
  case .contractor:
    guard let report = try? await store.context(record.id) else { return nil }
    return SessionContext(
      usedTokens: report.usedTokens,
      maxTokens: report.maxTokens,
      percentage: percentage(used: report.usedTokens, maxTokens: report.maxTokens),
      updatedAt: report.reportedAt.timeIntervalSince1970,
      source: .reported,
    )
  }
}

private func percentage(used: Int, maxTokens: Int) -> Double {
  guard maxTokens > 0 else { return 0 }
  return Double(used) / Double(maxTokens) * 100
}
