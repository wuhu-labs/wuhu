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
  /// Has the session's cell look at what a test wrote to its tables behind its back.
  func look(_ id: SessionID) async throws {
    try await writer.write { db in
      try Recipient<Look>(kind: SessionMail.kind, key: id.rawValue).post(.look, on: db.sqliteConnection!)
    }
    runtime.poke(id)
  }

  /// The cell's write of an input, for a test that drains it by hand.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await rows { try $0.put(id, SessionPut(input)) }
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

  func requestCommand(_ id: SessionID, _ command: SessionCommand) async throws {
    try await rows { try $0.requestCommand(id, command) }
    try await look(id)
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
  func takeCommand(_ id: SessionID) async throws -> SessionCommand? {
    try await rows { try $0.takeCommand(id) }
  }
}

private enum Look: Codable {
  case look
}
