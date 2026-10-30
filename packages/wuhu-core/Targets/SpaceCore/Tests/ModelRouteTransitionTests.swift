import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite(.deterministicDependencies) struct ModelRouteTransitionTests {
  @Test func failedAtomicCommitRecoversOldPairAndCommittedTransitionRecoversNewPair() async throws {
    let folder = try scratchURL("route-transition")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let store = space.sessions
      let old = SessionModelRouteTests().route()
      let id = try await store.createSession(group: .shared, title: "switch", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: old)
      let failure = ModelRouteFailure(reason: .quota, firstFailureAt: fixedDate, retryAt: fixedDate.addingTimeInterval(18000))
      try await store.updateModelRouteFailure(id, expectedEpoch: old.epoch, failure: failure)
      var source = try await store.hydrate(id).transcript.kernel
      let assistant = TranscriptItem.assistant(.init(id: UUID(), timestamp: fixedDate, content: [.text("portable text"), .reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "readable", opaque: "signature-a", id: "native-a", replayScope: "scope-a")))], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:], replayBinding: .init(identity: "scope-a", epoch: old.epoch)))
      source.append(assistant)
      try await store.append(id, items: [assistant], inputOrigin: source.cacheWarmingInputOrigin)
      let generation = try await store.generationState(id).generation
      var next = SessionModelRouteTests().route(member: "secondary", reason: .compaction)
      next.specifier.provider = "alternate"
      let portable = try source.portableHandoff(binding: .init(identity: "scope-b", epoch: next.epoch), budget: .init(maxInput: 100_000, maxOutput: 1000), runningWork: [])
      let transition = ModelRouteTransition(expectedEpoch: old.epoch, route: next, transcript: portable)
      guard case let .generationHead(head) = portable.items[0] else { Issue.record("missing head"); return }
      try await space.writer.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_transition BEFORE INSERT ON session_pointers WHEN NEW.generation > \(generation) BEGIN SELECT RAISE(ABORT, 'injected crash before commit'); END")
      }
      await #expect(throws: DatabaseError.self) {
        try await store.writeCompaction(id, head: head, kept: nil, transition: transition)
      }
      let beforeCommit = try Space.open(file: file)
      #expect(try await beforeCommit.sessions.modelRoute(id)?.epoch == old.epoch)
      #expect(try await beforeCommit.sessions.modelRoute(id)?.failure == failure)
      #expect(try await beforeCommit.sessions.generationState(id).generation == generation)
      #expect(try await beforeCommit.sessions.transcript(id).items == source.items)
      #expect(try await beforeCommit.sessions.modelRouteHistory(id) == [old])
      try await space.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_transition") }
      _ = try await store.writeCompaction(id, head: head, kept: nil, transition: transition)
      let afterCommit = try Space.open(file: file)
      #expect(try await afterCommit.sessions.modelRoute(id) == next)
      #expect(try await afterCommit.sessions.generationState(id).generation == generation + 1)
      #expect(try await afterCommit.sessions.modelRouteHistory(id) == [old, next])
      #expect(try await afterCommit.sessions.transcript(id).replayBinding?.epoch == next.epoch)
      let currentJSON = String(decoding: try JSONEncoder().encode(try await afterCommit.sessions.transcript(id)), as: UTF8.self)
      #expect(!currentJSON.contains("signature-a"))
      #expect(!currentJSON.contains("native-a"))
      let oldJSON = try await afterCommit.writer.read { db in try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE id = ?", arguments: [assistant.id.uuidString.lowercased()]) }
      #expect(oldJSON?.contains("signature-a") == true)
      let storedConfig = try await afterCommit.writer.read { db in try String.fetchOne(db, sql: "SELECT executor_config FROM sessions WHERE id = ?", arguments: [id.rawValue]) }
      #expect(storedConfig == SessionExecutor.kernel(next.specifier).configJSON)
      await #expect(throws: PortableHandoffConflict.routeChanged) { try await store.updateModelRouteFailure(id, expectedEpoch: old.epoch, failure: nil) }
    }
  }
}

extension ModelRouteTransitionTests {
  @Test func compactionTransitionRejectsOpaqueCarryWithoutChangingPinOrGeneration() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let old = SessionModelRouteTests().route()
      let id = try await store.createSession(group: .shared, title: "opaque rejection", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: old)
      let source = try await store.transcript(id)
      let generation = try await store.generationState(id).generation
      var next = SessionModelRouteTests().route(member: "secondary", reason: .compaction)
      next.specifier.provider = "alternate"
      let binding = ReplayBinding(identity: "scope-b", epoch: next.epoch)
      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compact", snapshot: .init(), replayBinding: binding, runningWork: [])
      var invalid = source.compacted(head: head, kept: nil)
      invalid.append(.assistant(.init(id: UUID(), timestamp: fixedDate, content: [.reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "readable", opaque: "signature-a", id: "native-a", replayScope: "scope-a")))], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:], replayBinding: binding)))
      #expect(invalid.replayBinding?.epoch == next.epoch)
      let transition = ModelRouteTransition(expectedEpoch: old.epoch, route: next, transcript: invalid)
      await #expect(throws: PortableHandoffConflict.routeChanged) {
        try await store.writeCompaction(id, head: head, kept: nil, transition: transition)
      }
      #expect(try await store.modelRoute(id) == old)
      #expect(try await store.modelRouteHistory(id) == [old])
      #expect(try await store.generationState(id).generation == generation)
      #expect(try await store.transcript(id).items == source.items)
    }
  }
}
