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

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  @discardableResult
  func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.archive(id, grace: grace) }
  }

  /// The cell's write of an input, which leaves the cell where it is: a test drains it by hand.
  func put(_ id: SessionID, input: QueueInput) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.put(id, SessionPut(input)) }
  }

  @discardableResult
  func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.drainQueue(id) }
  }

  /// Returns once every person's cell has taken the mail on its way: what a push outbox reads is then there.
  func inboxesSettled() async throws {
    for person in try await space.personas() {
      let address = PersonCell.ID(person.account.rawValue)
      space.worker.poke(address.recipient)
      while space.worker.hasMail(for: address.recipient) { await Task.yield() }
      try await space.worker.call(address) { _ in () }
    }
  }

  /// A person's inbox once their cell has taken the mail on its way.
  func inbox(_ recipient: String) async throws -> [NotificationRecord] {
    guard let person = spaceCell.personCell(recipient) else { return [] }
    space.worker.poke(person.recipient)
    while space.worker.hasMail(for: person.recipient) {
      await Task.yield()
    }
    try await space.worker.call(person) { _ in () }
    return notifications(recipient: recipient)
  }

  func deliverMail(_ id: SessionID) async throws {
    let address = SessionCell.ID(id.rawValue)
    space.worker.poke(address.recipient)
    while space.worker.hasMail(for: address.recipient) { await Task.yield() }
    try await space.worker.call(address) { _ in () }
  }

  /// Has the session's cell look at what a test wrote to its tables behind its back.
  func look(_ id: SessionID) async throws {
    space.worker.send(SessionCell.ID(id.rawValue)).look()
  }

  /// Nothing to do, and no mail on its way to the session's cell.
  ///
  /// Mail first: a cell takes a mail row and writes what it causes in one step, so no mail seen means the work read next is the work that mail left.
  func settledWork(_ id: SessionID) async throws -> Bool {
    guard !space.worker.hasMail(for: SessionCell.ID(id.rawValue).recipient) else { return false }
    return try await record(id).work == .noWork
  }

  /// Every input the session was sent, seen by its model or not, once its cell, which a worker runs, has taken its mail.
  func sent(_ id: SessionID) async throws -> [QueueInput] {
    try await deliverMail(id)
    return try space.worker.cell(SessionCell.ID(id.rawValue)).db.rows(
      SessionFixtureQueue.where { $0.sessionID.eq(id.rawValue) }.order { $0.id }.select(\.payload),
    ).map { try JSONDecoder().decode(QueueInput.self, from: Data($0.utf8)) }
  }

  func markInterrupted(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.markInterrupted(id) }
  }

  func markResumed(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.markResumed(id) }
  }

  @discardableResult
  func restart(_ id: SessionID, executor: SessionExecutor? = nil, note: String? = nil, modelRoute: SessionModelRoute? = nil, runningWork: [String] = []) async throws -> SessionRestart {
    @Dependency(\.uuid) var uuid
    let head = uuid()
    let restart = try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.restart(id, executor: executor, note: note, modelRoute: modelRoute, runningWork: runningWork, uuid: { head }) }
    let hydration = try await hydrate(id)
    if hydration.queueHead > hydration.queueTail { try await look(id) }
    return restart
  }

  @discardableResult
  func setTitle(_ id: SessionID, to title: String) async throws -> String {
    let title = try SessionStore.usableTitle(title)
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.retitle(id, title) }
    return title
  }

  func unarchive(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.unarchive(id) }
  }
}

@Table("session_queue")
struct SessionFixtureQueue {
  let id: Int64
  @Column("session_id") let sessionID: String
  let topic: String?
  let payload: String
}
