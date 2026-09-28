import Clocks
import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

// The has-unread column the app and SPA sidebars add to their session rows.
private let unreadSQL = """
SELECT id, EXISTS (
  SELECT 1 FROM notifications n
  WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = sessions.id
    AND n.n > COALESCE((SELECT last_read_n FROM watermarks w WHERE w.identity = viewer() AND w.source = sessions.id), 0)
) AS has_unread FROM sessions ORDER BY id
"""

struct UnreadTests {
  private let utc = TimeZone(identifier: "UTC")!

  @Test func hasUnreadFlipsOnAMessageAndClearsOnTheViewersWatermark() async throws {
    try await withSessionDeps {
      let space = try makeSpace(clock: ImmediateClock())
      let store = space.sessions
      let box = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.post(
        .box(box), messageID: MessageID("m1"), sender: Sender(id: "carol", timeZone: utc), content: .init(text: "q"),
      )

      let carol = Collector<Rows>()
      let stream = await space.observeQuery(unreadSQL, throttle: .zero, viewer: "carol")
      let consumer = Task { do { for try await rows in stream { await carol.append(rows) } } catch {} }
      defer { consumer.cancel() }
      #expect(await awaitItems(carol, atLeast: 1).last?.rows == [[.text(box.rawValue), .integer(0)]])

      _ = try await store.post(
        .box(box), messageID: MessageID("m2"),
        sender: Sender(id: box.rawValue, timeZone: utc), senderSession: box, replyTarget: MessageID("m1"),
        content: .init(text: "a"),
      )
      #expect(await awaitItems(carol, atLeast: 2).last?.rows == [[.text(box.rawValue), .integer(1)]])
      #expect(try await unread(space, viewer: "dave") == [[.text(box.rawValue), .integer(0)]])
      #expect(try await unread(space, viewer: nil) == [[.text(box.rawValue), .integer(0)]])

      try await store.advanceWatermark(identity: "dave", source: box.rawValue)
      #expect(try await unread(space, viewer: "carol") == [[.text(box.rawValue), .integer(1)]])

      try await store.advanceWatermark(identity: "carol", source: box.rawValue)
      let cleared = await awaitItems(carol, atLeast: 4)
      #expect(cleared.last?.rows == [[.text(box.rawValue), .integer(0)]])
    }
  }

  @Test func errorsAndDeadlinesLightNothing() async throws {
    try await withSessionDeps {
      let space = try makeSpace(clock: ImmediateClock())
      let store = space.sessions
      let box = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "owner", model: .test)
      _ = try await store.enqueue(box, input: SessionFix.message("do it"))
      _ = try await store.drainQueue(box)
      try await store.markErrored(box, message: "provider exploded")
      try await space.writer.write { db in
        try Notifications.append(
          recipient: Notifications.ownerRecipient, source: box.rawValue, group: .shared, kind: .requestDeadline,
          payload: "{}", now: SQLiteDateFormat.string(from: fixedDate), in: db,
        )
      }

      let kinds = try await store.notifications(recipient: "owner").map(\.kind)
      #expect(kinds == [.sessionErrored, .requestDeadline])
      #expect(try await unread(space, viewer: "owner") == [[.text(box.rawValue), .integer(0)]])
    }
  }

  private func unread(_ space: Space, viewer: String?) async throws -> [[Cell]] {
    try await space.query(unreadSQL, viewer: viewer).rows
  }
}
