#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Wuwei

extension SessionStore {
  @discardableResult
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.drainQueue(id) }
  }

  @discardableResult
  func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.archive(grace) }
    guard case let .archived(expires) = try await record(id).lifecycle else { preconditionFailure("archive commits its lifecycle") }
    return expires
  }

  func put(_ id: SessionID, input: QueueInput) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.rows.put(id, SessionPut(input)) }
  }

  func inbox(_ recipient: String) async throws -> [NotificationRecord] {
    let worker = space.worker
    guard let id = spaceCell.personCell(recipient) else { return [] }
    worker.poke(id.recipient)
    while worker.hasMail(for: id.recipient) { await Task.yield() }
    try await worker.call(id) { _ in () }
    return notifications(recipient: recipient)
  }

  func deliverMail() async throws {
    let worker = space.worker
    for group in try await space.groups() {
      let sessions = try await space.query("SELECT id FROM sessions", as: .init(actor: .anonymous, group: group.id))
      for row in sessions.rows {
        guard case let .text(session) = row[0] else { preconditionFailure("session ids are text") }
        let id = SessionCell.ID(session)
        worker.poke(id.recipient)
        while worker.hasMail(for: id.recipient) { await Task.yield() }
        try await worker.call(id) { _ in () }
      }
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

  func unarchive(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.unarchive() }
  }
}
