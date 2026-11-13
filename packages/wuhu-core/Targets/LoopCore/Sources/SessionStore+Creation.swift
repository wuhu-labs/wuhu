import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MainHub
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore

extension SessionStore {
  @discardableResult
  public func createSession(group: GroupID, title: String, kind: SessionKind, tags: [String] = [], createdBy: String, model: ModelSpecifier, snapshot: StateSnapshot? = nil) async throws -> SessionID {
    try await createSession(group: group, title: title, kind: kind, tags: tags, createdBy: createdBy, executor: .kernel(model), snapshot: snapshot)
  }

  @discardableResult
  public func createSession(group: GroupID, title: String, kind: SessionKind, parent: SessionID? = nil, tags: [String] = [], createdBy: String, executor: SessionExecutor, snapshot: StateSnapshot? = nil, modelRoute: SessionModelRoute? = nil, observer: Observer? = nil) async throws -> SessionID {
    try await createSession(SessionCreation(group: group, title: title, kind: kind, parent: parent, tags: tags, createdBy: createdBy, executor: executor, snapshot: snapshot, modelRoute: modelRoute, observer: observer))
  }

  public func createSession(_ input: SessionCreation) async throws -> SessionID {
    @Dependency(\.uuid) var uuid
    var input = input
    input.title = try Self.usableTitle(input.title)
    try input.validate()
    if let parent = input.parent { try space.worker.cell(SessionCell.ID(parent.rawValue)).checkParent() }
    if let observer = input.observer {
      if let refusal = try await space.worker.call(ObserverCell.ID(.group(observer.group), SubscriptionID(observer.name)), { try $0.admit() }) { throw refusal }
    }
    let allocation = try await space.allocate(.session, createdBy: input.createdBy)
    let id = SessionID(allocation.name)
    let head = input.snapshot.map { GenerationHead(id: uuid(), timestamp: allocation.createdAt, summary: "", snapshot: $0, runningWork: []) }
    let creation = input
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.create(creation, allocation: allocation.id, at: allocation.createdAt, head: head) }
    return id
  }

  public func enqueue(_ id: SessionID, input: QueueInput, topic: String? = nil, due: Date? = nil) async throws {
    let record = try space.worker.cell(SessionCell.ID(id.rawValue)).creationRecord()
    @Dependency(\.date.now) var now
    if case let .archived(deadline) = record.lifecycle, now >= deadline { throw SessionStoreError.archiveGraceExpired(id.rawValue) }
    space.worker.send(SessionCell.ID(id.rawValue)).put(SessionPut(input, topic: topic, due: due))
  }

  public func clear(_ id: SessionID, topic: String) async throws {
    space.worker.send(SessionCell.ID(id.rawValue)).clear(topic)
  }

  public func markErrored(_ id: SessionID, message: String) async throws {
    space.worker.send(SessionCell.ID(id.rawValue)).markErrored(message)
  }

  public func refuseControl(of target: SessionID, by actor: SessionID) async throws {
    _ = try space.worker.cell(SessionCell.ID(target.rawValue)).creationRecord()
    guard actor == target || space.worker.cell(SessionCell.ID(target.rawValue)).ancestors().contains(actor.rawValue) else {
      throw SessionStoreError.notInCharge(target.rawValue, actor: actor.rawValue)
    }
  }

  public func refuseArchiving(_ target: SessionID, by actor: Actor, acting: GroupID) async throws {
    let record = try space.worker.cell(SessionCell.ID(target.rawValue)).creationRecord()
    let admin = space.cell(of: record.group).role(of: actor, acting: acting) == .admin
    let allowed: Bool
    let label: String
    switch actor {
    case let .session(id):
      label = id.rawValue
      allowed = id == target || record.createdBy == id.rawValue || space.worker.cell(SessionCell.ID(target.rawValue)).ancestors().contains(id.rawValue) || admin
    case let .person(persona, account):
      label = persona
      allowed = space.cell.persona(record.createdBy, belongsTo: account) || admin
    case let .observer(observer):
      label = observer.member
      allowed = record.createdBy == observer.member || admin
    case let .page(page):
      label = page.path.rawValue
      allowed = false
    case .anonymous:
      label = "anonymous"
      allowed = true
    }
    guard allowed else { throw SessionStoreError.mayNotArchive(target.rawValue, actor: label) }
  }
}

extension SessionCell {
  func creationRecord() throws -> SessionRecord {
    try SessionCreation.record(id.session, in: db)
  }

  func checkParent() throws {
    try SessionCreation.checkParent(id.session, in: db)
  }

  func ancestors() -> [String] {
    SessionCreation.ancestors(of: id.key, in: db)
  }
}

extension SessionExecution {
  public var sessionEffects: SessionEffects {
    let store = store
    return SessionEffects(
      create: { try await store.createSession($0) },
      armObserver: { try await store.armObserver($0, $1, slot: $2, nextFireAt: $3, marker: $4) },
      cancelObserver: { try await store.cancelObserver($0, name: $1) },
      observers: { try await store.observers($0) },
      invalidatePromptRevision: { try await store.invalidatePromptRevision($0) },
    )
  }
}
