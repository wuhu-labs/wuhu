import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct SessionStoreTests {
  @Test func createAndHydrateEmptySession() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
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
    try await withSessionDeps {
      let store = try makeSpace().sessions
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

  @Test func storedQueuePayloadsAreCanonicalBytes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(sid, input: SessionFix.message("hello"))

      let payloads = try await space.writer.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT payload FROM session_queue",
        )
      }
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

  @Test func sessionIdsAreAllocatorDrawsInCreationOrder() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
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

      let secret = try await space.writer.read { db in
        Array(try Row.fetchOne(db, sql: "SELECT secret FROM allocation_freeze WHERE id = 1")!["secret"] as Data)
      }
      let decoded = ids.map { AllocationNames.id(for: $0.rawValue, words: AllocationVocabulary.words, secret: secret) }
      #expect(decoded == [1, 2, 3])

      let rows = try await space.writer.read { db in
        try Row.fetchAll(db, sql: "SELECT id, allocation FROM sessions ORDER BY allocation")
          .map { (id: $0["id"] as String, allocation: $0["allocation"] as Int64) }
      }
      #expect(rows.map(\.id) == ids.map(\.rawValue))
      #expect(rows.map(\.allocation) == [1, 2, 3])
      let kinds = try await space.writer.read { db in
        try String.fetchAll(db, sql: "SELECT kind FROM allocations ORDER BY id")
      }
      #expect(kinds == ["session", "session", "session"])
    }
  }

  @Test func erroredParksUntilResumeClearsTheError() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(sid, input: SessionFix.message())
      try await store.markErrored(sid, message: "boom")
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

  @Test func receiptsRoundTripAndFirstRecordWins() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let callID = ToolCallID("k-write-1")
      #expect(try await store.receipt(.session(sid), toolCallID: callID) == nil)

      let recorded = ToolResultPayload.write(.init(path: "/notes.md", revision: .journal(7)))
      try await store.recordReceipt(sid, toolCallID: callID, payload: recorded)
      #expect(try await store.receipt(.session(sid), toolCallID: callID) == recorded)

      try await store.recordReceipt(
        sid, toolCallID: callID, payload: .failure(.init(message: "retry must not overwrite")),
      )
      #expect(try await store.receipt(.session(sid), toolCallID: callID) == recorded)
    }
  }

  @Test func createSessionThrowsTypedOnAForeignReceipt() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let callID = ToolCallID("call_0")
      try await store.recordReceipt(
        sid, toolCallID: callID, payload: .write(.init(path: "/a.txt", revision: .journal(1))),
      )
      await #expect(throws: ForeignReceipt(toolCallID: callID)) {
        _ = try await store.createSession(
          group: .shared,
          title: "child", kind: .task, createdBy: sid.rawValue, model: .test,
          receipt: (holder: .session(sid), callID: callID),
        )
      }
    }
  }

  @Test func observationCallbacksSpeakForOneArmingAndOneDeliveryEach() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let session = try await store.createSession(
        group: .shared,
        title: "legacy", kind: .agent, createdBy: "morgan", model: .test,
      )
      let slot = SubscriptionSlot(
        id: .init("obs.legacy"),
        kind: .observe(sql: "SELECT 1", throttleSeconds: 1),
      )
      // A slot armed before observations carried their progress.
      let writer = await space.writer
      try await writer.write { db in
        try db.execute(
          sql: """
          INSERT INTO subscription_slots
            (owner_kind, owner, subscription_id, status, payload, marker, armed_at)
          VALUES ('session', ?, ?, 'armed', ?, ?, ?)
          """,
          arguments: [
            session.rawValue, slot.id.rawValue, try Sessions.encode(slot), "A", "2026-09-19T00:00:00.000Z",
          ],
        )
      }
      let legacy = try #require(await store.armedSubscriptions(session).first)
      #expect(legacy.slot.observationProgress == nil)

      func fire(_ token: UUID, marker: String, text: String) async throws -> Bool {
        try await store.rows { try $0.observed(session, slot.id, token: token, .change(text: text, marker: marker)) } == .stands
      }

      func armed() async throws -> ArmedSubscription {
        try #require(await store.armedSubscriptions(session).first)
      }

      #expect(try await fire(observationToken(legacy), marker: "B", text: "B"))
      #expect(try await armed().slot.observationProgress?.deliverySequence == 1)
      #expect(!(try await fire(observationToken(try await armed()), marker: "B", text: "B")))
      #expect(try await fire(observationToken(try await armed()), marker: "A", text: "A"))
      #expect(try await fire(observationToken(try await armed()), marker: "B", text: "B again"))

      let delivered = try await store.undrainedInputs(session).compactMap { entry -> SystemNotification? in
        guard case let .notification(notification) = entry.input else { return nil }
        return notification
      }
      #expect(delivered.map(\.content.text) == ["B again"], "each delivery replaces the one the model has not seen")
      #expect(try await armed().slot.observationProgress?.deliverySequence == 3)

      let cancelled = try await armed()
      try await store.rows { try $0.retire(session, slot.id) }
      #expect(!(try await fire(observationToken(cancelled), marker: "C", text: "late")))
      _ = try await store.armSubscription(session, slot: slot, marker: "B")
      #expect(!(try await fire(observationToken(cancelled), marker: "C", text: "old arming")))
      #expect(try await store.undrainedInputs(session).count == 1)
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
