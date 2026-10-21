import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite(.deterministicDependencies) struct PortableHandoffStoreTests {
  @Test(arguments: [false, true]) func rewrittenGenerationIsAtomicAndHistoryIsUntouched(hydrated: Bool) async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "portable", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init(preReads: ["/AGENTS.md"]))
      var original = try await store.transcript(id)
      let old = TranscriptItem.assistant(.init(id: UUID(), timestamp: fixedDate, content: [.reasoning(.encrypted(.init(providerID: "openai", model: "m", summary: "portable", opaque: "old-secret", id: "native")))], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:]))
      original.append(old)
      try await store.append(id, items: [old], inputOrigin: original.cacheWarmingInputOrigin)
      if hydrated { original = try await store.hydrate(id).transcript.kernel }
      let projected = try original.portableHandoff(binding: .init(identity: "binding-b", epoch: "route-b"), budget: .init(maxInput: 100_000, maxOutput: 1000), runningWork: [])
      let generation = try await store.generationState(id).generation
      var changed = original
      changed.append(.bookmark(.init(id: UUID(), timestamp: fixedDate)))
      await #expect(throws: PortableHandoffConflict.transcriptChanged) {
        try await store.writePortableHandoff(id, expectedGeneration: generation, source: changed, transcript: projected)
      }
      let written = try await store.writePortableHandoff(id, expectedGeneration: generation, source: original, transcript: projected)
      #expect(written.items.map(\.id) == projected.items.map(\.id))
      #expect(try await store.generationState(id).generation == generation + 1)
      #expect(try await store.transcript(id).replayBinding == projected.replayBinding)
      let json = String(decoding: try JSONEncoder().encode(try await store.transcript(id)), as: UTF8.self)
      #expect(!json.contains("old-secret"))
      let archived = try await space.writer.read { db in
        try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ? AND id = ?", arguments: [id.rawValue, old.id.uuidString.lowercased()])
      }
      let archivedContainsOriginal = archived?.contains("old-secret") == true
      #expect(archivedContainsOriginal)
      await #expect(throws: PortableHandoffConflict.generationChanged) { try await store.writePortableHandoff(id, expectedGeneration: generation, source: original, transcript: projected) }
      #expect(try await store.generationState(id).generation == generation + 1)
    }
  }
}
