import struct AgentsContract.AgentCells
import protocol AgentsContract.SessionReading
import struct AgentsContract.SessionSummary
import ControlledTime
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing
import Wuwei

@Suite(.deterministicDependencies(clock: VirtualClock())) struct FamilyReadContractTests {
  @Test func sessionHandlesKeepLifecycleForAdmissionAndGroupAccess() async throws {
    let space = try makeSpace()
    let session = try await space.sessions.createSession(group: .shared, title: "Agent", kind: .agent, createdBy: "owner", model: .test)
    let summary = try #require(space.cell._context.session(session).summary)
    #expect(summary.group == GroupID.shared.rawValue)
    #expect(summary.kind == .agent)
    #expect(summary.parent == nil)
    #expect(summary.createdBy == "owner")
    #expect(summary.lifecycle == .live)
    #expect(space.cell._context.session(SessionID("missing")).summary == nil)
    #expect(space.cell.group(of: session) == .shared)
    #expect(space.cell.directMessageTarget(session.rawValue) == session.rawValue)
    #expect(space.cell(of: .shared).role(of: .session(session), acting: .shared) == .admin)
    let box = try await space.sessions.conversation(ConversationID(session.rawValue))
    #expect(box.ownerSession == session)
    #expect(box.createdAt == summary.createdAt)
    let expiry = try await space.sessions.archive(session, grace: .seconds(60))
    let archived = try #require(space.cell._context.session(session).summary)
    #expect(archived.lifecycle == .archived(graceExpiresAt: expiry))
    #expect(space.cell(of: .shared).role(of: .session(session), acting: .shared) == nil)
    await space.stopWorker()
  }

  @Test func pushBadgeMatchesTheSQLiteJoinForEveryUnreadSourceKind() async throws {
    let space = try makeSpace()
    try await space.registerPerson("reader")
    let owner = try #require(space.cell.personCell("reader"))
    let live = try await space.sessions.createSession(group: .shared, title: "Live", kind: .agent, createdBy: "owner", model: .test)
    let read = try await space.sessions.createSession(group: .shared, title: "Read", kind: .agent, createdBy: "owner", model: .test)
    let archived = try await space.sessions.createSession(group: .shared, title: "Archived", kind: .agent, createdBy: "owner", model: .test)
    let task = try await space.sessions.createSession(group: .shared, title: "Task", kind: .task, createdBy: "owner", model: .test)
    _ = try await space.sessions.archive(archived, grace: .seconds(60))
    _ = try await space.addKey(testPubkey("badge"), account: AccountID(rawValue: owner.key), capabilities: [.device], createdBy: nil, expiresAt: nil)
    try await space.registerPushRelayGrant(PushRelayGrant(grant: "badge", endpoint: "https://push.invalid", token: "token", recipient: "reader", devicePublicKey: testPubkey("badge")))
    try await space.worker.call(owner) { cell in
      for (n, recipient, source, kind) in [
        (100, "reader", live.rawValue, "conversation_message"),
        (101, "reader", live.rawValue, "conversation_message"),
        (102, "reader", read.rawValue, "conversation_message"),
        (103, "reader", archived.rawValue, "conversation_message"),
        (104, "reader", task.rawValue, "conversation_message"),
        (105, "reader", "not-a-session", "conversation_message"),
        (106, "reader", read.rawValue, "session_settled"),
        (107, "someone-else", read.rawValue, "conversation_message"),
      ] {
        try cell.db.execute("INSERT INTO notifications (n, recipient, owner_account, source, kind, payload, created_at, grp) VALUES (?, ?, ?, ?, ?, '{}', '2026-01-01T00:00:00Z', 'shared')", .integer(Int64(n)), .text(recipient), .text(owner.key), .text(source), .text(kind))
      }
      try cell.db.execute("INSERT INTO watermarks (identity, owner_account, source, last_read_n) VALUES ('reader', ?, ?, 102)", .text(owner.key), .text(read.rawValue))
    }
    func badge(_ expected: Int) throws {
      let old = space.cell.db.one("""
      SELECT COUNT(DISTINCT u.source) FROM notifications u
      JOIN sessions s ON s.id = u.source AND s.kind = 'agent' AND s.lifecycle != 'archived'
      WHERE u.recipient = 'reader' AND u.kind = 'conversation_message'
        AND u.n > COALESCE((SELECT w.last_read_n FROM watermarks w WHERE w.identity = u.recipient AND w.source = u.source), 0)
      """)?.integer
      #expect(old == Int64(expected))
      #expect(space.cell.unreadConversations(recipient: "reader") == expected)
      let delivery = try #require(space.cell.duePushRelayDeliveries(at: fixedDate, limit: 64).first)
      #expect(delivery.unreadConversations == expected)
      #expect(space.cell.unreadConversations(recipient: "nobody") == 0)
    }
    try badge(1)
    await space.stopWorker()
  }

  @Test func factoriesCanBeReplacedAndUseTheCallersRead() async throws {
    let space = try Space.inMemory()
    let worker = Worker(id: "read-contract", storage: .shared(space.database), scheduler: DependencyScheduler(), registrations: [.cell(ReadCaller.self)])
    worker.provide(AgentCells(session: { reading, id in
      #expect(id == SessionID("session"))
      return reading.cell(ReadCaller.ID("caller"))
    }))
    try await worker.call(ReadCaller.ID("caller")) { cell in
      try cell.write(7)
      #expect(cell._context.session(SessionID("session")).summary?.group == "fake-7")
    }
    await worker.quiesce()
    worker.release()
    await space.stopWorker()
  }
}

@Cell
private struct ReadCaller: SessionReading {
  static let schema = ["CREATE TABLE read_caller (value INTEGER NOT NULL)"]

  mutating func write(_ value: Int64) throws {
    try db.execute("INSERT INTO read_caller VALUES (?)", .integer(value))
  }

  private var value: String { "fake-\(db.one("SELECT value FROM read_caller")!.integer!)" }

  var summary: SessionSummary? {
    SessionSummary(id: SessionID("session"), group: value, kind: .agent, parent: nil, createdAt: fixedDate, lifecycle: .live, createdBy: "fake")
  }
}
