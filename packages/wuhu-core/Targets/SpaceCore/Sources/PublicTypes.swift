import struct Foundation.Data
import struct Foundation.Date
import enum JSONValue.JSONValue
import struct OrderedCollections.OrderedDictionary
import struct SpaceFS.Entry
import struct SpaceFS.VersionToken
import struct SpaceIDs.GroupID

public struct Rev: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let value: Int

  public init(_ value: Int) {
    self.value = value
  }

  public static func < (lhs: Rev, rhs: Rev) -> Bool { lhs.value < rhs.value }
  public var description: String { String(value) }
}

public struct MutationEvent: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case write
    case delete
    case move
  }

  public let group: GroupID
  public let path: String
  public let from: String?
  public let rev: Int
  public let kind: Kind
  public let entry: Entry.Kind?

  public init(group: GroupID, path: String, from: String? = nil, rev: Int, kind: Kind, entry: Entry.Kind?) {
    self.group = group
    self.path = path
    self.from = from
    self.rev = rev
    self.kind = kind
    self.entry = entry
  }
}

public enum Change: Equatable, Sendable {
  case write(VersionToken)
  case delete
  case move(to: String)
  case checkout(fromRev: Int)
}

public struct TableColumn: Equatable, Sendable {
  public enum ColumnType: String, Equatable, Sendable {
    case text
    case integer
    case real
    case blob
    case boolean
    case json
  }

  public var name: String
  public var type: ColumnType

  public init(name: String, type: ColumnType) {
    self.name = name
    self.type = type
  }
}

public struct TableHeader: Equatable, Sendable {
  public var columns: [TableColumn]

  public init(columns: [TableColumn]) {
    self.columns = columns
  }
}

public enum RowOp: Sendable {
  case insert([JSONValue])
  case update(id: Int64, [JSONValue])
  case delete(id: Int64)
}

/// A named-field row op: each value in its wire cell form, a scalar,
/// `{"blob": base64}` or `{"json": value}`, checked against the column's type.
public enum RowEdit: Equatable, Sendable {
  case insert(OrderedDictionary<String, JSONValue>)
  /// The named fields only; the others keep their values.
  case update(id: Int64, OrderedDictionary<String, JSONValue>)
  case delete(id: Int64)
}

/// What one row mutation committed: its revision and the inserted row ids, in
/// op order.
public struct RowCommit: Equatable, Sendable {
  public let rev: Rev
  public let ids: [Int64]

  public init(rev: Rev, ids: [Int64]) {
    self.rev = rev
    self.ids = ids
  }
}

public struct RevisionAttribution: Codable, Equatable, Sendable {
  public let actor: String?
  public let via: String

  public init(actor: String?, via: String) {
    self.actor = actor
    self.via = via
  }

  public init?(firing observer: Observer) {
    guard let firing = observer.firing else { return nil }
    self.init(actor: observer.member, via: Self.firingVia(firing))
  }

  public static func firingVia(_ firing: String) -> String { "firing:\(firing)" }
}

public enum Cell: Equatable, Sendable, Codable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])

  public var byteCount: Int {
    switch self {
    case .null: 0
    case .integer, .real: 8
    case let .text(text): text.utf8.count
    case let .blob(bytes): bytes.count
    }
  }
}

public struct Rows: Equatable, Sendable, Codable {
  public var columns: [String]
  public var decltypes: [String?]
  public var rows: [[Cell]]

  public init(columns: [String], decltypes: [String?], rows: [[Cell]]) {
    self.columns = columns
    self.decltypes = decltypes
    self.rows = rows
  }
}

extension VersionToken {
  init(rev: Int) {
    self.init(Data(String(rev).utf8))
  }

  var rev: Int? {
    String(data: bytes, encoding: .utf8).flatMap(Int.init)
  }
}
