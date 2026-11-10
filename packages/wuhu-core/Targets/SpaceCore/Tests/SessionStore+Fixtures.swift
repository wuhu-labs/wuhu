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

  /// The cell's write of an input, which answers with its place in the queue.
  @discardableResult
  func put(_ id: SessionID, input: QueueInput, topic: String? = nil, due: Date? = nil, throttle: Double? = nil) async throws -> Int {
    try await rows { rows in
      try rows.put(id, SessionPut(input, topic: topic, due: due, throttle: throttle))
      return try Int.fetchOne(rows.db, sql: "SELECT id FROM session_queue WHERE session_id = ? AND input_id = ?", arguments: [id.rawValue, input.id.uuidString.lowercased()])!
    }
  }

  /// What the session cells do with the mail main posted, for a test with no worker.
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

  func markResumed(_ id: SessionID) async throws {
    try await rows { try $0.markResumed(id) }
  }

  func requestCommand(_ id: SessionID, _ command: SessionCommand) async throws {
    try await rows { try $0.requestCommand(id, command) }
    runtime.poke(id)
  }

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    @Dependency(\.uuid) var uuid
    let head = uuid()
    let restart = try await rows { try $0.restart(id, executor: executor, note: note, modelRoute: modelRoute, runningWork: runningWork, uuid: { head }) }
    let hydration = try await hydrate(id)
    if hydration.queueHead > hydration.queueTail { runtime.poke(id) }
    return restart
  }

  func setTags(_ id: SessionID, to tags: [String]) async throws {
    try await rows { try $0.retag(id, tags) }
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
