import Foundation
import SessionDomain
import Testing
import WuhuAI

struct WorkTests {
  @Test func emptyTranscriptHasNoWork() {
    #expect(!Transcript().hasWork)
    #expect(Transcript().pendingToolCallIDs.isEmpty)
  }

  @Test func inputAtTailIsWork() {
    #expect(Transcript(items: [Fix.direct()]).hasWork)
    #expect(Transcript(items: [Fix.message()]).hasWork)
    #expect(Transcript(items: [Fix.notification()]).hasWork)
  }

  @Test func plainAssistantTailSettles() {
    let transcript = Transcript(items: [Fix.direct(), Fix.assistant(totalTokens: 10)])
    #expect(!transcript.hasWork)
  }

  @Test func pendingToolCallIsWork() {
    let call = ToolCall(id: "k-1", name: "read", arguments: .object([:]))
    let transcript = Transcript(items: [
      Fix.direct(),
      Fix.assistant(totalTokens: 10, toolCalls: [call]),
    ])
    #expect(transcript.pendingToolCallIDs == [ToolCallID("k-1")])
    #expect(transcript.hasWork)
  }

  @Test func toolResultSatisfiesCallButTailContinues() {
    let call = ToolCall(id: "k-1", name: "grep", arguments: .object([:]))
    let transcript = Transcript(items: [
      Fix.direct(),
      Fix.assistant(totalTokens: 10, toolCalls: [call]),
      Fix.result(.grep(.init(output: "hit")), provenance: .toolCall(.init("k-1"))),
    ])
    #expect(transcript.pendingToolCallIDs.isEmpty)
    #expect(transcript.hasWork)
  }

  @Test func bookmarkMarkerSatisfiesItsCall() {
    let call = ToolCall(id: "k-b", name: "bookmark", arguments: .object([:]))
    let transcript = Transcript(items: [
      Fix.direct(),
      Fix.assistant(totalTokens: 10, toolCalls: [call]),
      .bookmark(.init(id: UUID(), timestamp: Fix.instant, toolCallID: .init("k-b"))),
    ])
    #expect(transcript.pendingToolCallIDs.isEmpty)
    #expect(transcript.hasWork)
  }

  @Test func generationHeadTailIsWork() {
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "s", snapshot: .init())
    #expect(Transcript(items: [.generationHead(head)], keptCount: 1).hasWork)
  }

  @Test func queueInputMapsToItsTranscriptItem() {
    let item = Fix.message()
    guard case let .message(message) = item else { fatalError() }
    let input = QueueInput.message(message)
    #expect(input.id == message.id)
    #expect(input.transcriptItem == item)
    #expect(input.transcriptItem.id == input.id)
  }
}
