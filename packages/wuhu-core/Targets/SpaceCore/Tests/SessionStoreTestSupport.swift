import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore

extension SessionStore {
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.drainQueue(id) }
  }

  @discardableResult
  func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.archive(grace) }
    guard case let .archived(deadline) = try await record(id).lifecycle else { preconditionFailure("archive did not archive") }
    return deadline
  }

  /// The cell's write of an input, which answers with its place in the queue.
  @discardableResult
  func put(_ id: SessionID, input: QueueInput, topic: String? = nil, due: Date? = nil, throttle: Double? = nil) async throws -> Int {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { cell in
      let rows = cell.rows
      try rows.put(id, SessionPut(input, topic: topic, due: due, throttle: throttle))
      return try Int.fetchOne(rows.db, sql: "SELECT id FROM session_queue WHERE session_id = ? AND input_id = ?", arguments: [id.rawValue, input.id.uuidString.lowercased()])!
    }
  }

  /// A person's inbox once their cell has taken the mail on its way.
  func inbox(_ recipient: String) async throws -> [NotificationRecord] {
    let worker = space.worker
    guard let person = spaceCell.personCell(recipient) else { return [] }
    worker.poke(person.recipient)
    while worker.hasMail(for: person.recipient) { await Task.yield() }
    try await worker.call(person) { _ in () }
    return notifications(recipient: recipient)
  }

  /// How many of `identity`'s notifications from `source` are past its read mark.
  func unreadCount(identity: String, source: String) async throws -> Int {
    _ = try await inbox(identity)
    return try await writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
        SELECT COUNT(*) FROM notifications
        WHERE recipient = ? AND source = ?
          AND n > COALESCE((SELECT last_read_n FROM watermarks WHERE identity = ? AND source = ?), 0)
        """,
        arguments: [identity, source, identity, source],
      )!
    }
  }

  func deliverMail() async throws {
    let worker = space.worker
    let sessions = try await writer.read { try String.fetchAll($0, sql: "SELECT id FROM sessions") }
    for session in sessions {
      let id = SessionCell.ID(session)
      worker.poke(id.recipient)
      while worker.hasMail(for: id.recipient) { await Task.yield() }
      try await worker.call(id) { _ in () }
    }
  }

  func markInterrupted(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.interrupt() }
  }

  func markResumed(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.resume() }
  }

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.restart(executor, modelRoute, note, runningWork) }
    return try await SessionRestart(generation: generation(id), executor: record(id).executor)
  }

  func setTags(_ id: SessionID, to tags: [String]) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.retag(tags) }
  }

  @discardableResult
  func setTitle(_ id: SessionID, to title: String) async throws -> String {
    let title = try SessionStore.usableTitle(title)
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.retitle(title) }
    return title
  }

  func unarchive(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.unarchive() }
  }
}
