import Foundation
import SessionDomain
import SpaceCore
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata

// The store no longer reads a transcript back when appending. A test that is
// not driving a loop holds none, so it reads one here rather than making the
// production path carry the cost.
extension SessionStore {
  func appendAssistant(
    _ id: SessionID,
    attemptID: UUID,
    message: AssistantMessage,
    metadata: AssistantMessageMetadata,
  ) async throws {
    var transcript = try await transcript(id)
    let before = transcript.items.count
    transcript.appendAssistant(message, id: attemptID, metadata: metadata)
    try await append(id, items: Array(transcript.items[before...]), transcript: transcript)
  }
}

extension SessionStore {
  func writeToolResult(_ id: SessionID, _ item: ToolResultItem) async throws {
    try await appendReadingBack(id, [.toolResult(item)])
  }

  func writeBookmark(_ id: SessionID, _ marker: BookmarkMarker) async throws {
    try await appendReadingBack(id, [.bookmark(marker)])
  }

  private func appendReadingBack(_ id: SessionID, _ items: [TranscriptItem]) async throws {
    var transcript = try await transcript(id)
    for item in items { transcript.append(item) }
    try await append(id, items: items, transcript: transcript)
  }
}

extension SessionTranscript {
  var kernel: Transcript {
    guard case let .kernel(transcript) = self else { preconditionFailure("expected a kernel transcript, got \(self)") }
    return transcript
  }
}
