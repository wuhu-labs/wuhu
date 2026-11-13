#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import SessionDomain
import struct SpaceContract.GroupID
import SpaceSQL
import StructuredQueries
import Wuwei
import WuweiQueries

public struct ObservationSlot: Hashable, Codable, Sendable {
  public let owner: SubscriptionOwner
  public let subscription: SubscriptionID
  public let incarnation: UUID

  public var key: String { encoded(self) }
}

public enum ObservationPrincipal: Codable, Sendable {
  case session(SessionID)
  case observer(group: GroupID, name: String)
}

public struct ObservationWatch: Codable, Sendable {
  public let slot: ObservationSlot
  let statement: String
  let principal: ObservationPrincipal
  let recipient: Recipient<ObservationReply>
  let marker: String?
}

public enum ObservationMail: Codable, Sendable {
  public static let recipient = Recipient<Self>(kind: "ObservationJob", key: "streams")
  case watch(ObservationWatch)
  case unwatch(ObservationSlot)
}

public enum ObservationReply: Codable, Sendable {
  case observed(ObservationSlot, Rows, String)
  case failed(ObservationSlot, String)
}

public func rowsMarker(_ rows: Rows) -> String {
  SHA256.hash(data: Data(rows.json.jsonString().utf8)).map { String(format: "%02x", $0) }.joined()
}

func encoded(_ value: some Encodable) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  return String(decoding: try! encoder.encode(value), as: UTF8.self)
}

func decoded<T: Decodable>(_ type: T.Type, _ value: String) -> T {
  try! JSONDecoder().decode(type, from: Data(value.utf8))
}

extension ArmedSubscription {
  public var observationSlot: ObservationSlot {
    ObservationSlot(owner: owner, subscription: slot.id, incarnation: observationToken(self))
  }

  public func watch(recipient: Recipient<ObservationReply>) -> ObservationWatch {
    let sql: String
    let baseline: String?
    switch slot.kind {
    case let .observe(statement, _):
      sql = statement
      baseline = marker
    case .children:
      sql = SubscriptionSlot.childrenQuery(owner.session!)
      baseline = rowsMarker(Rows(columns: ["id", "title", "error"], decltypes: ["TEXT", "TEXT", nil], rows: []))
    case .timer, .stream: preconditionFailure("only SQL slots have a query watch")
    }
    let principal: ObservationPrincipal = switch owner {
    case let .session(id): .session(id)
    case let .group(group): .observer(group: group, name: name!)
    }
    return ObservationWatch(slot: observationSlot, statement: sql, principal: principal, recipient: recipient, marker: baseline)
  }
}

extension ObservationPrincipal {
  func resolve(in snapshot: ReadSnapshot) throws -> Principal {
    switch self {
    case let .session(id):
      guard let row = try snapshot.rows(GroupSessionRow.where { $0.id.eq(id.rawValue) }).first else { throw SpaceError.notFound(id.rawValue) }
      return Principal(actor: .session(id), group: GroupID(rawValue: row.grp))
    case let .observer(group, name):
      return Observer(group: group, name: name, firing: nil).principal
    }
  }
}

extension GroupAccess {
  static func scope(for principal: Principal, viewer: String?, in snapshot: ReadSnapshot) throws -> ReadScope {
    let access = try Snapshot(groups: snapshot.rows(GroupRow.all), roles: snapshot.rows(GroupRoleRow.all))
    let rows = ActorRows<any Error>(
      session: { id in try snapshot.rows(GroupSessionRow.where { $0.id.eq(id.rawValue) }).first },
      account: { id in try snapshot.rows(GroupAccountRow.where { $0.id.eq(id.rawValue) }).first },
    )
    return try ReadScope(acting: principal.group, readable: access.readable(by: principal.actor, acting: principal.group, rows: rows), viewer: viewer, member: principal.member)
  }
}
