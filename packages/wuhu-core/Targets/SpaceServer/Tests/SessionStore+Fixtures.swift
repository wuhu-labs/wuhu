import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
@testable import SpaceCore
import Wuwei

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  @discardableResult
  func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await rows {
      return try $0.archive(id, grace: grace)
    }
  }

  /// The cell's write of an input, which leaves the cell where it is: a test drains it by hand.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await rows { try $0.put(id, SessionPut(input)) }
  }

  @discardableResult
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await rows { try $0.drainQueue(id) }
  }

  /// Returns once every person's cell has taken the mail on its way: what a push outbox reads is then there.
  func inboxesSettled() async throws {
    while try await writer.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient LIKE 'PersonCell/%')")! }) {
      await Task.yield()
    }
  }

  /// A person's inbox once their cell has taken the mail on its way.
  func inbox(_ recipient: String) async throws -> [NotificationRecord] {
    _ = runtime.worker()
    runtime.poke(person: recipient)
    while try await writer.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["PersonCell/" + recipient])! }) {
      await Task.yield()
    }
    return notifications(recipient: recipient)
  }

  /// What the session cells do with the mail main posted, for a test that runs no worker.
  func deliverMail() async throws {
    try await rows { rows in
      let prefix = SessionMail.kind + "/"
      for row in try Row.fetchAll(rows.db, sql: "SELECT id, recipient, payload FROM wuwei_mail WHERE recipient LIKE ? ORDER BY id", arguments: [prefix + "%"]) {
        let id = SessionID(String((row["recipient"] as String).dropFirst(prefix.count)))
        switch try? JSONDecoder().decode(SessionMail.self, from: row["payload"] as Data) {
        case let .put(put): try rows.put(id, put)
        case let .clear(topic): try rows.clear(id, topic: topic)
        default: continue
        }
        try rows.db.execute(sql: "DELETE FROM wuwei_mail WHERE id = ?", arguments: [row["id"] as Int64])
      }
    }
  }

  /// Has the session's cell look at what a test wrote to its tables behind its back.
  func look(_ id: SessionID) async throws {
    try await writer.write { db in
      try Recipient<Look>(kind: SessionMail.kind, key: id.rawValue).post(.look, on: db.sqliteConnection!)
    }
    runtime.poke(id)
  }

  /// Nothing to do, and no mail on its way to the session's cell.
  func settledWork(_ id: SessionID) async throws -> Bool {
    try await writer.read { db in
      try Sessions.record(id.rawValue, in: db).work == .noWork
        && Bool.fetchOne(db, sql: "SELECT NOT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["\(SessionMail.kind)/\(id.rawValue)"])!
    }
  }

  /// Every input the session was sent, seen by its model or not, once its cell, which a worker runs, has taken its mail.
  func sent(_ id: SessionID) async throws -> [QueueInput] {
    try await until("the session's cell takes its mail") {
      try await writer.read {
        try Bool.fetchOne($0, sql: "SELECT NOT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["\(SessionMail.kind)/\(id.rawValue)"])!
      }
    }
    return try await writer.read { try Sessions.undrained(id.rawValue, tail: 0, at: "9999", in: $0) }.map(\.input)
  }

  func markInterrupted(_ id: SessionID) async throws {
    try await rows { try $0.markInterrupted(id) }
  }

  func markResumed(_ id: SessionID) async throws {
    try await rows { try $0.markResumed(id) }
  }

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    @Dependency(\.uuid) var uuid
    let head = uuid()
    let restart = try await rows { try $0.restart(id, executor: executor, note: note, modelRoute: modelRoute, runningWork: runningWork, uuid: { head }) }
    let hydration = try await hydrate(id)
    if hydration.queueHead > hydration.queueTail { try await look(id) }
    return restart
  }

  @discardableResult
  func setTitle(_ id: SessionID, to title: String) async throws -> String {
    let title = try SessionStore.usableTitle(title)
    try await rows { try $0.retitle(id, title) }
    return title
  }

  func unarchive(_ id: SessionID) async throws {
    try await rows { try $0.unarchive(id) }
  }
}

private enum Look: Codable {
  case look
}
