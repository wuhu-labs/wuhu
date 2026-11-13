import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SessionCreationTests {
  @Test func createAndHydrateEmptySession() async throws {
    try await withSessionHandlerDeps {
      let store = try makeHandlerSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "Build", kind: .agent, tags: ["ops"], createdBy: "morgan", model: .test)
      let hydration = try await store.hydrate(sid)
      #expect(hydration.record.id == sid)
      #expect(hydration.record.title == "Build")
      #expect(hydration.record.tags == ["ops"])
      #expect(hydration.record.createdBy == "morgan")
      #expect(hydration.record.hold == .normal)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.lifecycle == .live)
      #expect(hydration.record.errorMessage == nil)
      #expect(!hydration.legacy)
      #expect(try await store.transcriptLines(sid).isEmpty)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(hydration.queueHead == 0)
      #expect(hydration.queueTail == 0)
      let second = try await store.createSession(group: .shared, title: "again", kind: .agent, createdBy: "morgan", model: .test)
      #expect(second != sid)
      let unknown = SessionID("no-such-session")
      await #expect(throws: SessionStoreError.unknownSession(unknown.rawValue)) {
        _ = try await store.hydrate(unknown)
      }
    }
  }

  @Test func createWithSnapshotSeedsAGenerationZeroHead() async throws {
    try await withSessionHandlerDeps {
      let store = try makeHandlerSpace().sessions
      let snapshot = StateSnapshot(preReads: ["/AGENTS.md"])
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: snapshot)

      let hydration = try await store.hydrate(sid)
      #expect(hydration.record.work == .noWork, "creation stays inert")
      #expect(!hydration.legacy)
      let lines = try await store.transcriptLines(sid)
      #expect(lines.map(\.key) == ["head"])
      #expect(try lines[0].line().message.text.contains("/AGENTS.md"))
    }
  }

  @Test func sessionIdsAreAllocatorDrawsInCreationOrder() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let ids = [
        try await store.createSession(group: .shared, title: "one", kind: .agent, createdBy: "morgan", model: .test),
        try await store.createSession(group: .shared, title: "two", kind: .agent, createdBy: "morgan", model: .test),
        try await store.createSession(group: .shared, title: "three", kind: .agent, createdBy: "morgan", model: .test),
      ]
      #expect(Set(ids).count == 3)
      let vocabulary = Set(AllocationVocabulary.words)
      for id in ids {
        let words = id.rawValue.split(separator: "-").map(String.init)
        #expect(words.count >= 3)
        #expect(words.allSatisfy { vocabulary.contains($0) })
      }

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      let secret = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
      #expect(ids.map(\.rawValue) == (1 ... 3).map {
        AllocationNames.name(for: Int64($0), words: AllocationVocabulary.words, secret: secret)
      })
      let next = try await space.allocate(.device, createdBy: "morgan")
      #expect(next.id == 4)
      #expect(next.kind == .device)
    }
  }
}
