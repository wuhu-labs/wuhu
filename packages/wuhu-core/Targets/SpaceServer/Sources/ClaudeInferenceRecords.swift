import enum ClaudeStream.ClaudeStreamFrame
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionID
import struct SpaceCore.InferenceRecord
import class SpaceCore.Space

func recordClaudeInferences(
  _ calls: [ClaudeStreamFrame.Assistant], space: Space, session: SessionID, model: ModelSpecifier, logger: Logger,
) async {
  for call in calls {
    do {
      let at = try Date(call.timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
      try await space.recordInference(InferenceRecord(
        id: session.rawValue + "/" + call.id, session: session, at: at,
        provider: model.provider, model: model.model, servedModel: call.model, effort: model.effort,
        input: call.usage.inputTokens, cacheRead: call.usage.cacheReadInputTokens,
        cacheWrite: call.usage.cacheCreationInputTokens, output: call.usage.outputTokens,
        outcome: "ok",
      ))
    } catch {
      logger.error("Claude inference database write failed", metadata: ["session": "\(session.rawValue)", "error": "\(error)"])
    }
  }
}
