import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import StructuredQueries
import Testing

@Suite(.deterministicDependencies)
struct SessionStoreTests {
  @Test func storedQueuePayloadsAreCanonicalBytes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(sid, input: SessionFix.message("hello"))

      let payloads = space.worker.cell(SessionCell.ID(sid.rawValue)).db.rows(SessionQueueRow.where { $0.sessionID.eq(sid.rawValue) }.select { $0.payload })
      #expect(payloads.count == 1)
      for payload in payloads {
        #expect(keysAreSorted(try #require(JSONValue.parse(payload))), "unsorted keys in \(payload)")
      }
    }
  }

  @Test func retriedEnqueueDedupsOnInputID() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let input = SessionFix.message("once")
      #expect(try await store.put(sid, input: input) == 1)
      #expect(try await store.put(sid, input: input) == 1)
      #expect(try await store.undrainedInputs(sid).count == 1)

      _ = try await store.drainQueue(sid)
      // A retry after materialization must return the recorded id, not
      // re-enter the queue: the retained row is the dedup receipt.
      #expect(try await store.put(sid, input: input) == 1)
      let hydration = try await store.hydrate(sid)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(hydration.queueTail == 1)
    }
  }

  @Test func erroredParksUntilResumeClearsTheError() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(sid, input: SessionFix.message())
      try await store.markErrored(sid, message: "boom")
      try await store.deliverMail()
      var record = try await store.record(sid)
      #expect(record.work == .errored)
      #expect(record.errorMessage == "boom")

      _ = try await store.drainQueue(sid)
      #expect(try await store.record(sid).work == .errored)

      try await store.markResumed(sid)
      record = try await store.record(sid)
      #expect(record.work == .noWork, "the cell shows its turn after resume")
      #expect(record.errorMessage == nil)
      #expect(record.hold == .normal)
    }
  }

  @Test func interruptAndResumeToggleHold() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.markInterrupted(sid)
      #expect(try await store.record(sid).hold == .interrupted)
      try await store.markResumed(sid)
      #expect(try await store.record(sid).hold == .normal)
    }
  }
}

private func keysAreSorted(_ value: JSONValue) -> Bool {
  switch value {
  case let .object(fields):
    Array(fields.keys) == fields.keys.sorted() && fields.values.allSatisfy(keysAreSorted)
  case let .array(items):
    items.allSatisfy(keysAreSorted)
  default:
    true
  }
}
