#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import StructuredQueries
import Wuwei
import WuweiQueries

struct IdentitySchedule: Codable, Sendable {
  var current: String
  var rotatedAt: Date
  var next: String?
  var overlapBeganAt: Date?
  var switchedAt: Date?

  var signer: String { switchedAt == nil ? current : next! }
  var keys: [String] { [current] + (next.map { [$0] } ?? []) }
}

enum IdentityBootstrap: Codable, Sendable {
  case fresh(String)
  case imported(IdentitySchedule)
}

struct IdentityState: Codable, Sendable {
  var defaultIssuer: IssuerChoice = .self
  var overrides: [String: IssuerChoice] = [:]
  var directoryID: String?
  var schedule: IdentitySchedule
  var confirmed = false
  var failure: IdentityError?
  var pending: IdentityWork?
  var retry: IdentityRetry?
  var generating = false
  var registeringNew = false

  var usesDirectory: Bool { defaultIssuer == .directory || overrides.values.contains(.directory) || directoryID != nil }
  var rotating: Bool { generating || schedule.next != nil }
}

struct IdentityRetry: Codable, Sendable {
  let at: Date
  let action: IdentityWork.Action
}

struct IdentityWork: Codable, Sendable {
  enum Action: String, Codable { case generate, publish, retire, register }
  let id: String
  let action: Action
}

@Table("server_identity")
struct IdentityRow: Owned {
  @Column(as: IdentityState.JSONRepresentation.self) var state: IdentityState
}

@Cell
struct IdentityCell {
  static let schema = ["CREATE TABLE server_identity (\(ownerColumn), state TEXT NOT NULL, UNIQUE(owner))"]

  func state() -> IdentityState? { db.rows(IdentityRow.all).first?.state }

  mutating func initialize(_ bootstrap: IdentityBootstrap, defaultIssuer: IssuerChoice, overrides: [String: IssuerChoice], directoryID: String?) throws {
    precondition(state() == nil)
    let schedule: IdentitySchedule = switch bootstrap {
    case let .fresh(kid): IdentitySchedule(current: kid, rotatedAt: now)
    case let .imported(schedule): schedule
    }
    try save(IdentityState(defaultIssuer: defaultIssuer, overrides: overrides, directoryID: directoryID, schedule: schedule), inserting: true)
    try advance()
  }

  mutating func set(defaultIssuer: IssuerChoice?, audience: String?, choice: IssuerChoice?) throws -> IdentityState {
    var state = state()!
    if let defaultIssuer { state.defaultIssuer = defaultIssuer }
    if let audience {
      try IdentityController.validateAudience(audience)
      state.overrides[audience] = choice
    }
    if !state.usesDirectory {
      state.registeringNew = false
      if state.retry?.action != .generate {
        state.retry = nil
        state.failure = nil
      }
    }
    try save(state)
    if state.pending == nil, state.usesDirectory { try launch(.publish) }
    return self.state()!
  }

  mutating func rotate() throws -> IdentityState {
    var state = state()!
    guard !state.rotating else { throw IdentityError.busy }
    state.generating = true
    try save(state)
    if state.pending == nil { try launch(.generate) }
    return self.state()!
  }

  mutating func registerNew() throws -> IdentityState {
    var state = state()!
    guard state.usesDirectory else { throw IdentityError.directoryNotSelected }
    guard state.pending == nil, !state.rotating || (!state.confirmed && (state.failure == .unknownId || state.failure == .unlistedKey)) else { throw IdentityError.busy }
    state.registeringNew = true
    try save(state)
    try launch(.register)
    return self.state()!
  }

  mutating func finished(_ work: IdentityWork, _ result: IdentityWorkResult) throws {
    var state = state()!
    precondition(state.pending?.id == work.id)
    state.pending = nil
    switch result {
    case let .generated(kid):
      precondition(work.action == .generate && state.generating)
      state.schedule.next = kid
      state.generating = false
      if state.failure == .keyUnavailable { state.failure = nil }
    case let .published(directoryID):
      precondition(work.action != .generate)
      if let directoryID, state.usesDirectory { state.directoryID = directoryID }
      state.confirmed = true
      state.retry = nil
      state.failure = nil
      if work.action == .register { state.registeringNew = false }
      if work.action == .retire {
        state.schedule = IdentitySchedule(current: state.schedule.signer, rotatedAt: now)
      } else if state.schedule.next != nil, state.schedule.overlapBeganAt == nil {
        state.schedule.overlapBeganAt = now
      }
    case let .failed(failure):
      if work.action == .generate || state.usesDirectory {
        state.failure = failure
        state.retry = IdentityRetry(at: now.addingTimeInterval(60), action: work.action)
        if work.action == .publish || work.action == .retire { state.confirmed = false }
      }
    }
    try save(state)
    if state.retry == nil { try advance() }
  }

  func nextWake() -> Instant? {
    guard let state = state(), state.pending == nil else { return nil }
    let due: Date
    if let retry = state.retry { due = retry.at }
    else if state.generating || (state.usesDirectory && !state.confirmed) { due = now }
    else if state.schedule.next == nil { due = state.schedule.rotatedAt.addingTimeInterval(90 * 86400) }
    else if state.schedule.overlapBeganAt == nil { due = now }
    else if let switched = state.schedule.switchedAt { due = max(state.schedule.overlapBeganAt!.addingTimeInterval(2 * 86400), switched.addingTimeInterval(86400)) }
    else { due = state.schedule.overlapBeganAt!.addingTimeInterval(86400) }
    return Instant(milliseconds: Int64((due.timeIntervalSince1970 * 1000).rounded(.up)))
  }

  mutating func wake() throws { try advance() }

  private mutating func advance() throws {
    var state = state()!
    precondition(state.pending == nil)
    if let retry = state.retry {
      precondition(retry.at <= now)
      state.retry = nil
      try save(state)
      return try launch(retry.action)
    }
    if state.registeringNew { return try launch(.register) }
    if state.generating { return try launch(.generate) }
    if state.schedule.next == nil, state.schedule.rotatedAt.addingTimeInterval(90 * 86400) <= now {
      state.generating = true
      try save(state)
      return try launch(.generate)
    }
    if state.usesDirectory, !state.confirmed { return try launch(.publish) }
    guard state.schedule.next != nil else { return }
    if state.schedule.overlapBeganAt == nil {
      if state.usesDirectory { return try launch(.publish) }
      state.schedule.overlapBeganAt = now
    }
    if state.schedule.switchedAt == nil, state.schedule.overlapBeganAt!.addingTimeInterval(86400) <= now { state.schedule.switchedAt = now }
    if let switched = state.schedule.switchedAt, max(state.schedule.overlapBeganAt!.addingTimeInterval(2 * 86400), switched.addingTimeInterval(86400)) <= now {
      if state.usesDirectory {
        try save(state)
        return try launch(.retire)
      }
      state.schedule = IdentitySchedule(current: state.schedule.signer, rotatedAt: now)
    }
    try save(state)
  }

  private mutating func launch(_ action: IdentityWork.Action) throws {
    var state = state()!
    precondition(state.pending == nil)
    let work = IdentityWork(id: ctx.dependency(IdentityClient.self).uuid().uuidString.lowercased(), action: action)
    state.pending = work
    if action == .publish || action == .retire { state.confirmed = false }
    try save(state)
    ctx.create(IdentityJob.ID(work.id), params: .init(cell: id, work: work))
  }

  private mutating func save(_ state: IdentityState, inserting: Bool = false) throws {
    if inserting { try db.execute(IdentityRow.insert { IdentityRow(state: state) }) }
    else { try db.execute(IdentityRow.update { $0.state = #bind(state) }) }
  }

  private var now: Date { Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000) }
}
