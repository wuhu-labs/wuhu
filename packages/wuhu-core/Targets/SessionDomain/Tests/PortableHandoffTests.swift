import Dependencies
import Foundation
import SessionDomain
import Testing
import WuhuAI

@Suite struct PortableHandoffTests {
  let binding = ReplayBinding(identity: "account-b", epoch: "route-2")
  let budget = ContextBudget(maxInput: 20000, maxOutput: 1000)

  @Test func projectionPreservesOutstandingInputAndReceiptsButNotOpacity() throws {
    try withDependencies {
      $0.uuid = UUIDGenerator { UUID() }
      $0.date = DateGenerator { Fix.instant }
    } operation: {
      let question = Fix.message(kind: .request, request: "r-1", text: "complete indispensable task")
      let call = ToolCall(id: "kernel-receipt", name: "write", arguments: .object([:]))
      let assistant = TranscriptItem.assistant(.init(
        id: UUID(), timestamp: Fix.instant,
        content: [
          .reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "readable summary", opaque: "NEVER_SEND_SIGNATURE", replayScope: "a"))),
          .reasoning(.encrypted(.init(providerID: "anthropic", model: "m", opaque: "NEVER_SEND_REDACTED", redacted: true))),
          .toolCall(call),
        ],
        stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: ["native": .init(call.id)],
        replayBinding: .init(identity: "account-a", epoch: "route-1"),
      ))
      let receipt = Fix.result(.failure(.init(message: "write receipt")), provenance: .toolCall(.init(call.id)))
      let original = Transcript(items: [question, assistant, receipt])
      #expect(original.hasUnscopedReplay)
      let portable = try original.portableHandoff(binding: binding, budget: budget, runningWork: ["script.running"])
      guard case let .generationHead(head) = portable.items[0] else { Issue.record("missing head"); return }
      #expect(head.runningWork == ["script.running"])
      #expect(portable.replayBinding == binding)
      #expect(!portable.hasUnscopedReplay)
      #expect(portable.items.contains(question))
      #expect(portable.items.contains(receipt))
      #expect(portable.environment.settle == original.environment.settle)
      #expect(portable.pendingToolCallIDs.isEmpty)
      let rewritten = try #require(portable.items.compactMap { item -> AssistantEntry? in
        if case let .assistant(entry) = item { return entry }; return nil
      }.first)
      #expect(rewritten.id != assistant.id)
      #expect(rewritten.toolCalls == [call])
      #expect(rewritten.toolCallIDs == ["native": .init(call.id)])
      #expect(rewritten.content.contains(.text("readable summary")))
      let json = String(decoding: try JSONEncoder().encode(portable), as: UTF8.self)
      #expect(!json.contains("NEVER_SEND"))
      #expect(String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains("NEVER_SEND_SIGNATURE"))
    }
  }

  @Test func indispensableInputIsNeverClippedToFit() {
    withDependencies {
      $0.uuid = UUIDGenerator { UUID() }
      $0.date = DateGenerator { Fix.instant }
    } operation: {
      let original = Transcript(items: [Fix.message(kind: .request, request: "r", text: String(repeating: "full task ", count: 2000))])
      #expect(throws: PortableHandoffError.modelHandoffTooLarge) {
        try original.portableHandoff(binding: binding, budget: .init(maxInput: 1000, maxOutput: 100), runningWork: [])
      }
    }
  }

  @Test func pendingSideEffectsMustCompleteBeforeCrossing() {
    let original = Transcript(items: [Fix.assistant(totalTokens: 1, toolCalls: [.init(id: "pending", name: "exec", arguments: .object([:]))])])
    #expect(throws: PortableHandoffError.outstandingToolCalls) { try original.portableHandoff(binding: binding, budget: budget, runningWork: []) }
  }

  @Test func noneModeProjectsEveryReplayWithoutRepeatedLegacyBoundaries() {
    let entry = AssistantEntry(id: UUID(), timestamp: Fix.instant, content: [.reasoning(.encrypted(.init(providerID: "openai", model: "m", opaque: "no-affinity")))], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:], replayBinding: binding)
    let transcript = Transcript(items: [.assistant(entry)])
    #expect(transcript.hasUnscopedReplay)
    #expect(!transcript.requiresReplayHandoff(to: binding.identity))
    #expect(transcript.requiresReplayHandoff(to: "new-account"))
    var legacy = entry
    legacy.replayBinding = nil
    #expect(Transcript(items: [.assistant(legacy)]).requiresReplayHandoff(to: binding.identity))
  }

  @Test func priorGenerationHeadCannotOverridePortableBinding() throws {
    try withDependencies {
      $0.uuid = UUIDGenerator { UUID() }
      $0.date = DateGenerator { Fix.instant }
    } operation: {
      let old = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "previous summary", snapshot: .init(), replayBinding: .init(identity: "old", epoch: "old"), runningWork: [])
      let transcript = Transcript(items: [.generationHead(old), Fix.message(kind: .request, request: "r", text: "full task")])
      let portable = try transcript.portableHandoff(binding: binding, budget: budget, runningWork: [])
      #expect(portable.replayBinding == binding)
      #expect(!portable.requiresReplayHandoff(to: binding.identity))
      #expect(portable.items.filter { if case .generationHead = $0 { return true }; return false }.count == 1)
      #expect(portable.environment.settle == transcript.environment.settle)
    }
  }

  @Test func ordinaryCompactionAndCodableKeepBinding() throws {
    let original = Transcript(items: [.assistant(.init(id: UUID(), timestamp: Fix.instant, content: [.text("safe")], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:], replayBinding: binding))])
    let compacted = original.compacted(head: .init(id: UUID(), timestamp: Fix.instant, summary: "summary", snapshot: .init(), runningWork: []), kept: nil)
    #expect(compacted.replayBinding == binding)
    #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(compacted)).replayBinding == binding)
  }
}
