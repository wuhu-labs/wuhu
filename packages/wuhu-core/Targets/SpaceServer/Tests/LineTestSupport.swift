import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import WuhuAI

extension SessionStore {
  func testLines(_ id: SessionID, generation: Int? = nil) async throws -> [TranscriptLine] {
    try await transcriptLines(id, generation: generation).map { try $0.line() }
  }

  func appendTestLines(_ id: SessionID, _ lines: [TranscriptLine]) async throws {
    _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.append(id, lines: lines) }
  }

  func appendReply(_ id: SessionID, attemptID: UUID = UUID(), message: AssistantMessage, metadata: AssistantMessageMetadata) async throws {
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    let entry = AssistantEntry(message, id: attemptID, at: now, metadata: metadata, replayBinding: nil, mint: { ToolCallID(uuid().uuidString.lowercased()) })
    try await appendTestLines(id, TranscriptItem.assistant(entry).lines(session: id))
  }

  @discardableResult
  func foldLines(_ id: SessionID, head: GenerationHead, kept: Range<Int>? = nil, transition: ModelRouteTransition? = nil) async throws -> [TranscriptLine] {
    var head = head
    head.replayBinding = transition?.binding
    let after = transition?.notice.map {
      TranscriptItem.notification(SystemNotification(id: UUID(), timestamp: head.timestamp, kind: .context, subscriptionID: ModelRouteTransition.source, content: .init(text: $0))).lines(session: id)
    } ?? []
    let opening = head
    let generation = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.writeGeneration(id, head: opening, kept: transition?.carriesTail == false ? nil : kept, after: after, transition: transition) }
    return try await testLines(id, generation: generation)
  }
}

extension TranscriptLine {
  var text: String {
    let content = switch message {
    case let .user(message): message.content
    case let .assistant(message): message.content
    case let .toolResult(message): message.content
    }
    return content.compactMap { block in
      if case let .text(text) = block { text.text } else { nil }
    }.joined(separator: "\n")
  }
}
