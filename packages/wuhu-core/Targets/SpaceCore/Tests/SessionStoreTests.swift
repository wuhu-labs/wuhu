import Dependencies
import Foundation
import GRDB
import JSONValue
import SessionDomain
@_spi(SessionObservation) @testable import SpaceCore
import Testing
import WuhuAI

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
      #expect(hydration.transcript.kernel == Transcript())
      #expect(hydration.undrained.isEmpty)
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
      #expect(hydration.transcript.kernel.keptCount == 1)
      guard case let .generationHead(head)? = hydration.transcript.kernel.items.first, hydration.transcript.kernel.items.count == 1 else {
        Issue.record("expected exactly the seeded generation head, got \(hydration.transcript.kernel.items)")
        return
      }
      #expect(head.summary.isEmpty)
      #expect(head.snapshot == snapshot)
      #expect(hydration.transcript.kernel.needsReestablishment)
    }
  }

  @Test func hydrationRoundTripsWritesQueueAndPointers() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.enqueue(sid, input: SessionFix.message("hello")) == 1)
      #expect(try await store.enqueue(sid, input: SessionFix.message("ping")) == 2)
      _ = try await store.drainQueue(sid)
      var transcript = try await store.transcript(sid)
      #expect(transcript.items.count == 2)

      let call = ToolCall(id: "call_0", name: "grep", arguments: .object(["pattern": .string("x")]))
      try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("on it", toolCalls: [call]), metadata: SessionFix.metadata,
      )
      transcript = try await store.transcript(sid)
      guard case let .assistant(entry) = transcript.items.last else {
        Issue.record("expected assistant entry")
        return
      }
      try await store.writeToolResult(sid, SessionFix.toolResult(callID: entry.toolCalls[0].id))
      transcript = try await store.transcript(sid)
      #expect(try await store.enqueue(sid, input: SessionFix.notification()) == 3)

      let hydration = try await store.hydrate(sid)
      #expect(hydration.transcript.kernel == transcript)
      #expect(hydration.undrained.map(\.id) == [3])
      #expect(hydration.queueHead == 3)
      #expect(hydration.queueTail == 2)
      #expect(hydration.record.work == .hasWork)
    }
  }

  @Test func toolCallArgumentsSurviveTheStoreVerbatim() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let emitted = #"{"command":"bash -lc 'ls -la'", "max_output":30000,"timeout_seconds":30}"#
      let call = ToolCall(id: "call_0", name: "exec", arguments: try #require(ToolArguments(verbatim: emitted)))
      _ = try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("on it", toolCalls: [call]), metadata: SessionFix.metadata,
      )

      // Repeatedly: Foundation's keyed decoding has handed back a different key
      // order on a later pass over identical bytes.
      for pass in 1 ... 8 {
        guard case let .assistant(entry) = try await store.hydrate(sid).transcript.kernel.items.last else {
          Issue.record("expected assistant entry on pass \(pass)")
          return
        }
        #expect(entry.toolCalls[0].arguments.text == emitted)
      }
    }
  }

  // The caller owns the transcript it renders from, but not where a row lands:
  // a stale count must not be able to overwrite a pointer.
  @Test func appendPositionsRowsFromTheStoreNotTheCaller() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message("one"))
      _ = try await store.enqueue(sid, input: SessionFix.message("two"))
      _ = try await store.drainQueue(sid)

      let marker = BookmarkMarker(id: UUID(), timestamp: Date(timeIntervalSinceReferenceDate: 0))
      try await store.append(sid, items: [.bookmark(marker)], transcript: Transcript(items: [.bookmark(marker)]))

      let stored = try await store.transcript(sid)
      #expect(stored.items.count == 3)
      #expect(stored.items.last?.id == marker.id)
    }
  }

  @Test func storedPayloadsAreCanonicalBytes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let call = ToolCall(id: "call_0", name: "grep", arguments: .object(["pattern": .string("x")]))
      _ = try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("on it", toolCalls: [call]), metadata: SessionFix.metadata,
      )
      _ = try await store.enqueue(sid, input: SessionFix.message("hello"))

      let payloads = try await space.writer.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT payload FROM session_contents UNION ALL SELECT payload FROM session_queue",
        )
      }
      #expect(payloads.count == 2)
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
      #expect(try await store.enqueue(sid, input: input) == 1)
      #expect(try await store.enqueue(sid, input: input) == 1)
      #expect(try await store.hydrate(sid).undrained.count == 1)

      _ = try await store.drainQueue(sid)
      // A retry after materialization must return the recorded id, not
      // re-enter the queue: the retained row is the dedup receipt.
      #expect(try await store.enqueue(sid, input: input) == 1)
      let hydration = try await store.hydrate(sid)
      #expect(hydration.undrained.isEmpty)
      #expect(hydration.queueTail == 1)
    }
  }

  @Test func workFlipsCommitWithTheTranscript() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.record(sid).work == .noWork)

      _ = try await store.enqueue(sid, input: SessionFix.message())
      #expect(try await store.record(sid).work == .hasWork)

      _ = try await store.drainQueue(sid)
      #expect(try await store.record(sid).work == .hasWork)

      _ = try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant(), metadata: SessionFix.metadata)
      let settled = try await store.hydrate(sid)
      #expect(settled.record.work == .noWork)
      #expect(settled.transcript.kernel.items.count == 2)
    }
  }

  @Test func failedWriteRollsBackFlipAndAppendTogether() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let inputID = UUID()
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message(id: inputID))
      _ = try await store.drainQueue(sid)
      _ = try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant(), metadata: SessionFix.metadata)
      #expect(try await store.record(sid).work == .noWork)

      // Colliding with an existing content id makes the append fail mid
      // transaction; the work flip it would have carried must vanish with it.
      await #expect(throws: DatabaseError.self) {
        _ = try await store.writeToolResult(sid, SessionFix.toolResult(callID: "k-1", id: inputID))
      }
      let hydration = try await store.hydrate(sid)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.transcript.kernel.items.count == 2)
    }
  }

  @Test func aKernelSettleQueuesNoNag() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message("please review", conversation: sid.rawValue, owesReply: true))
      _ = try await store.drainQueue(sid)

      _ = try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("done thinking"), metadata: SessionFix.metadata,
      )
      let hydration = try await store.hydrate(sid)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.undrained.isEmpty, "the loop nags from its transcript; the store queues nothing")
      #expect(try await store.armedSubscriptions(sid).isEmpty)
    }
  }

  @Test func aHeadWithoutASettleStateTakesTheStoresAsOfTheHead() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
    _ = try await store.enqueue(sid, input: SessionFix.message("before", message: "m1", conversation: sid.rawValue, owesReply: true))
    _ = try await store.drainQueue(sid)
    rig.advance(60)
    let head = GenerationHead(id: UUID(), timestamp: rig.store.dateGen.now, summary: "compacted", snapshot: .init())
    _ = try await store.writeCompaction(sid, head: head, kept: nil)
    rig.advance(60)
    _ = try await store.enqueue(sid, input: SessionFix.message("after", message: "m2", conversation: "elsewhere", owesReply: true))
    _ = try await store.drainQueue(sid)

    let transcript = try await store.hydrate(sid).transcript.kernel
    guard case let .generationHead(hydrated) = transcript.items.first else {
      Issue.record("a compacted generation opens with its head")
      return
    }
    #expect(hydrated.settle?.owedConversations == [ConversationID(sid.rawValue)])
    #expect(Set(transcript.environment.settle.owedConversations) == [ConversationID("elsewhere"), ConversationID(sid.rawValue)])
  }

  @Test func compactionMintsGenerationAndSharesKeptContent() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let keptID = UUID()
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message("old"))
      _ = try await store.drainQueue(sid)
      _ = try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant(), metadata: SessionFix.metadata)
      _ = try await store.enqueue(sid, input: SessionFix.message("recent", id: keptID))
      _ = try await store.drainQueue(sid)
      let before = try await store.transcript(sid)
      #expect(before.items.count == 3)

      let head = GenerationHead(
        id: UUID(),
        timestamp: fixedDate,
        summary: "compacted",
        snapshot: .init(),
        settle: SettleState(),
      )
      let compacted = try await store.writeCompaction(sid, head: head, kept: 2 ..< 3)
      #expect(compacted.items.count == 2)
      #expect(compacted.keptCount == 2)
      #expect(compacted.items[0] == .generationHead(head))
      #expect(compacted.items[1].id == keptID)

      let hydration = try await store.hydrate(sid)
      #expect(hydration.transcript.kernel == compacted)

      let keptRows = try await space.writer.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM session_contents WHERE session_id = ? AND id = ?",
          arguments: [sid.rawValue, keptID.uuidString.lowercased()],
        )!
      }
      #expect(keptRows == 1)
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

  @Test func bootSelectsLiveSessionsWithWork() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let working = try await store.createSession(group: .shared, title: "working", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.createSession(group: .shared, title: "idle", kind: .agent, createdBy: "morgan", model: .test)
      let errored = try await store.createSession(group: .shared, title: "errored", kind: .agent, createdBy: "morgan", model: .test)
      let archived = try await store.createSession(group: .shared, title: "archived", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(working, input: SessionFix.message())
      _ = try await store.enqueue(errored, input: SessionFix.message())
      try await store.markErrored(errored, message: "provider exploded")
      _ = try await store.enqueue(archived, input: SessionFix.message())
      _ = try await store.archive(archived, grace: .seconds(3600))

      #expect(try await store.bootSessions() == [working])
    }
  }

  @Test func erroredParksUntilResumeRederives() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message())
      try await store.markErrored(sid, message: "boom")
      var record = try await store.record(sid)
      #expect(record.work == .errored)
      #expect(record.errorMessage == "boom")

      // Errored is sticky across transcript writes until an explicit resume.
      _ = try await store.drainQueue(sid)
      #expect(try await store.record(sid).work == .errored)

      try await store.markResumed(sid)
      record = try await store.record(sid)
      #expect(record.work == .hasWork)
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
      #expect(try await store.receipt(sid, toolCallID: callID) == nil)

      let recorded = ToolResultPayload.write(.init(path: "/notes.md", revision: .journal(7)))
      try await store.recordReceipt(sid, toolCallID: callID, payload: recorded)
      #expect(try await store.receipt(sid, toolCallID: callID) == recorded)

      try await store.recordReceipt(
        sid, toolCallID: callID, payload: .failure(.init(message: "retry must not overwrite")),
      )
      #expect(try await store.receipt(sid, toolCallID: callID) == recorded)
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
          receipt: (session: sid, callID: callID),
        )
      }
    }
  }

  @Test func reschedulingMustAdvanceThePersistedDueTimeBeforeEnqueuing() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let session = try await store.createSession(group: .shared, title: "timer", kind: .agent, createdBy: "morgan", model: .test)
      let due = fixedDate
      let slot = SubscriptionSlot(id: .init("timer.advance"), kind: .timer(.cron("* * * * *"), message: "tick"))
      try await store.armSubscription(session, slot: slot, nextFireAt: due)
      let notification = SystemNotification(id: UUID(), timestamp: due, kind: .timer, subscriptionID: slot.id, content: .init(text: "tick"))
      for next in [due.addingTimeInterval(-60), due, due.addingTimeInterval(0.0001)] {
        await #expect(throws: NonAdvancingSubscription.self) {
          try await store.fireSubscription(session, subscriptionID: slot.id, notification: notification, advance: .reschedule(next))
        }
        #expect(try await store.hydrate(session).undrained.isEmpty)
        #expect(try await store.armedSubscriptions(session).first?.nextFireAt == due)
      }
      try await store.fireSubscription(session, subscriptionID: slot.id, notification: notification, advance: .reschedule(due.addingTimeInterval(60)))
      #expect(try await store.hydrate(session).undrained.count == 1)
      #expect(try await store.armedSubscriptions(session).first?.nextFireAt == due.addingTimeInterval(60))
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
          INSERT INTO session_subscriptions
            (session_id, subscription_id, payload, marker, armed_at)
          VALUES (?, ?, ?, ?, ?)
          """,
          arguments: [
            session.rawValue, slot.id.rawValue, try Sessions.encode(slot), "A", "2026-09-19T00:00:00.000Z",
          ],
        )
      }
      let legacy = try #require(await store.armedSubscriptions(session).first)
      #expect(legacy.slot.observationProgress == nil)

      func fire(_ token: UUID, marker: String, text: String) async -> Bool {
        let notification = SystemNotification(
          id: token,
          timestamp: Date(timeIntervalSince1970: 0),
          kind: .spaceObservation,
          subscriptionID: slot.id,
          content: .init(text: text),
        )
        return (try? await store.fireSubscription(
          session,
          subscriptionID: slot.id,
          notification: notification,
          advance: .observed(marker: marker),
        )) != nil
      }

      func armed() async throws -> ArmedSubscription {
        try #require(await store.armedSubscriptions(session).first)
      }

      #expect(await fire(observationToken(legacy), marker: "B", text: "B"))
      #expect(try await armed().slot.observationProgress?.deliverySequence == 1)
      #expect(!(await fire(observationToken(try await armed()), marker: "B", text: "B")))
      #expect(await fire(observationToken(try await armed()), marker: "A", text: "A"))
      #expect(await fire(observationToken(try await armed()), marker: "B", text: "B again"))

      let delivered = try await store.hydrate(session).undrained.compactMap { entry -> SystemNotification? in
        guard case let .notification(notification) = entry.input else { return nil }
        return notification
      }
      #expect(delivered.map(\.content.text) == ["B", "A", "B again"])
      #expect(Set(delivered.map(\.id)).count == 3)

      let cancelled = try await armed()
      try await store.cancelSubscription(session, subscriptionID: slot.id)
      #expect(!(await fire(observationToken(cancelled), marker: "C", text: "late")))
      _ = try await store.armSubscription(session, slot: slot, marker: "B")
      #expect(!(await fire(observationToken(cancelled), marker: "C", text: "old arming")))
      #expect(try await store.hydrate(session).undrained.count == 3)
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
