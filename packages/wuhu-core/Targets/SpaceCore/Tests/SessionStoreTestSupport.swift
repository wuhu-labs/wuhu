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

extension SessionStore {
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.drainQueue(id) }
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
      try cell.put(id, SessionPut(input, topic: topic, due: due, throttle: throttle))
      return Int(cell.db.rows(SessionQueueRow.where { $0.sessionID.eq(id.rawValue) && $0.inputID.eq(input.id.uuidString.lowercased()) }.select { $0.id }).first!)
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
    guard let person = spaceCell.personCell(identity) else { return 0 }
    let db = space.worker.cell(person).db
    let mark = db.rows(WatermarkRow.where { $0.identity.eq(identity) && $0.source.eq(source) }.select { $0.lastReadN }).first ?? 0
    return db.rows(NotificationRow.where { $0.recipient.eq(identity) && $0.source.eq(source) && $0.n.gt(mark) }.asSelect().count()).first!
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
