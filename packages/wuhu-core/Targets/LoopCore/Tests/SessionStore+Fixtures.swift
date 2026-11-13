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
import Wuwei

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  @discardableResult
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.drainQueue(id) }
  }

  func look(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.look() }
  }

  /// The cell's write of an input, for a test that drains it by hand.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.put(id, SessionPut(input)) }
  }

  func noMail(_ id: SessionID) async {
    let recipient = SessionCell.ID(id.rawValue).recipient
    while space.worker.hasMail(for: recipient) { await Task.yield() }
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

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.restart(executor, modelRoute, note, runningWork) }
    return try await SessionRestart(generation: generation(id), executor: record(id).executor)
  }
}
