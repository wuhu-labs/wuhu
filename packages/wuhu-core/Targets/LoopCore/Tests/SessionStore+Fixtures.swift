import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import StructuredQueries
import Wuwei

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  @discardableResult
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.drainQueue(id) }
  }

  func look(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.look() }
  }

  /// The cell's write of an input, for a test that drains it by hand.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.put(id, SessionPut(input)) }
  }

  func noMail(_ id: SessionID) async {
    let recipient = SessionCell.ID(id.rawValue).recipient
    while space.worker.hasMail(for: recipient) { await Task.yield() }
  }

  func deliverMail() async throws {
    let worker = space.worker
    let sessions = spaceCell.db.rows(SessionDataRow.select { $0.id })
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
