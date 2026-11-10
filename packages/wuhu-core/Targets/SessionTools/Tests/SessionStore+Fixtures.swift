import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
@testable import SpaceCore

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  @discardableResult
  func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await rows {
      return try $0.archive(id, grace: grace)
    }
  }

  /// The cell's write of an input, for a test that runs no worker.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await rows { try $0.put(id, SessionPut(input)) }
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

  func markInterrupted(_ id: SessionID) async throws {
    try await rows { try $0.markInterrupted(id) }
  }

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    @Dependency(\.uuid) var uuid
    let head = uuid()
    let restart = try await rows { try $0.restart(id, executor: executor, note: note, modelRoute: modelRoute, runningWork: runningWork, uuid: { head }) }
    return restart
  }

  func unarchive(_ id: SessionID) async throws {
    try await rows { try $0.unarchive(id) }
  }
}
