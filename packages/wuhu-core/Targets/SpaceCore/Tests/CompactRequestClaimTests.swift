import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct CompactRequestClaimTests {
  @Test(arguments: [nil, "keep the notes"] as [String?])
  func claimIsDurableAndIdempotentUntilAssistantCommit(instructions: String?) async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "compact", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: instructions))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      let repeated = try #require(try await store.claimCompactRequest(id, generation: 0))
      #expect(claim == repeated)
      #expect(try await store.pendingCommand(id) == .compact(instructions: instructions))
      #expect(try await store.hydrate(id).transcript.kernel == claim.transcript)
      #expect(claim.transcript.items.count == (instructions == nil ? 0 : 1))
      var transcript = claim.transcript
      transcript.appendAssistant(SessionFix.assistant("folding"), id: UUID(), metadata: SessionFix.metadata)
      try await store.append(id, items: [try #require(transcript.items.last)], inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      #expect(try await store.pendingCommand(id) == nil)
    }
  }

  @Test(arguments: ["old", "new"])
  func committedOldTurnDoesNotConsumeAReplacementCommand(replacementInstructions: String) async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "replacement", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: "old"))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      try await store.requestCommand(id, .compact(instructions: replacementInstructions))
      var transcript = claim.transcript
      transcript.appendAssistant(SessionFix.assistant(), id: UUID(), metadata: SessionFix.metadata)
      try await store.append(id, items: [try #require(transcript.items.last)], inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      #expect(try await store.pendingCommand(id) == .compact(instructions: replacementInstructions))
      let replacement = try #require(try await store.claimCompactRequest(id, generation: 0))
      #expect(replacement.transcript.items.count == 3)
    }
  }

  @Test func restartRejectsAnOldClaimBeforeMaterializationOrCompletion() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "restart", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: "same instructions"))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      try await store.markInterrupted(id)
      _ = try await store.restart(id)
      try await store.requestCommand(id, .compact(instructions: "same instructions"))
      #expect(try await store.claimCompactRequest(id, generation: 0) == nil)
      var transcript = claim.transcript
      transcript.appendAssistant(SessionFix.assistant(), id: UUID(), metadata: SessionFix.metadata)
      await #expect(throws: CancellationError.self) {
        try await store.append(id, items: [try #require(transcript.items.last)], inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      }
      #expect(try await store.pendingCommand(id) == .compact(instructions: "same instructions"))
      #expect(try await store.hydrate(id).transcript.kernel.items.count == 1)
      #expect(try await store.hydrate(id).generation == 1)
    }
  }

  @Test func appendFailureRollsBackCommandAcknowledgement() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "rollback", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: "keep"))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      var transcript = claim.transcript
      let duplicate = try #require(transcript.items.first)
      transcript.appendAssistant(SessionFix.assistant("fresh"), id: UUID(), metadata: SessionFix.metadata)
      let fresh = try #require(transcript.items.last)
      transcript.append(duplicate)
      await #expect(throws: (any Error).self) {
        try await store.append(id, items: [fresh, duplicate], inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      }
      #expect(try await store.pendingCommand(id) == .compact(instructions: "keep"))
      #expect(try await store.hydrate(id).transcript.kernel == claim.transcript)
    }
  }

  // A worker that could not see its append commit sends it again; main holds
  // the items once and answers as it did the first time.
  @Test func anAppendRepeatedIsTheFirstAppend() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "replay", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: "keep"))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      var transcript = claim.transcript
      transcript.appendAssistant(SessionFix.assistant("once"), id: UUID(), metadata: SessionFix.metadata)
      let items = [try #require(transcript.items.last)]
      try await store.append(id, items: items, inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      try await store.append(id, items: items, inputOrigin: transcript.cacheWarmingInputOrigin, completingCompactRequest: claim)
      #expect(try await store.hydrate(id).transcript.kernel == transcript)
      #expect(try await store.pendingCommand(id) == nil)
    }
  }

  @Test func mechanicalCompactionAcknowledgesTheClaimInItsCommit() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "mechanical", kind: .agent, createdBy: "morgan", model: .test)
      try await store.requestCommand(id, .compact(instructions: nil))
      let claim = try #require(try await store.claimCompactRequest(id, generation: 0))
      _ = try await store.writeCompaction(id, head: .init(id: UUID(), timestamp: fixedDate, summary: "kept", snapshot: .init(), runningWork: []), kept: nil, completingCompactRequest: claim)
      #expect(try await store.pendingCommand(id) == nil)
      #expect(try await store.hydrate(id).generation == 1)
    }
  }
}
