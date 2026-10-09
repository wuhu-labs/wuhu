import struct Foundation.Data
import struct Foundation.Date
import enum JSONValue.JSONValue
import struct OrderedCollections.OrderedDictionary
import struct SpaceContract.GroupID
import struct SpaceFS.Entry
import struct SpaceFS.VersionToken

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

/// Who a revision acts for when a page wrote it: the viewer (nil for the --dev
/// seat) and the page's path in its group.
public struct RevisionAttribution: Equatable, Sendable {
  public let actor: String?
  public let via: String

  public init(actor: String?, via: String) {
    self.actor = actor
    self.via = via
  }
}

public enum Cell: Equatable, Sendable {
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

public struct Rows: Equatable, Sendable {
  public var columns: [String]
  public var decltypes: [String?]
  public var rows: [[Cell]]

  public init(columns: [String], decltypes: [String?], rows: [[Cell]]) {
    self.columns = columns
    self.decltypes = decltypes
    self.rows = rows
  }
}

public enum SpaceError: Error, Equatable, Sendable {
  case notFound(String)
  case notAFile(String)
  case notATable(String)
  case notADirectory(String)
  case pathIsDirectory(String)
  case alreadyExists(String)
  case malformedPubkey(String)
  case versionMismatch(String)
  case invalidRevision(Int)
  case columnCountMismatch(String)
  case columnTypeChanged(String)
  case invalidTableHeader(String)
  case invalidCellValue(String)
  case reservedTablePath(String)
  case reservedAccountName(String)
  case lastAdmin(String)
  case readOnlyView(String)
  /// A write, move or remove under `wuhu://system/`, which ships in the binary.
  case systemReadOnly(String)
  case foreignHome(path: String, owner: String)
  case queryNotReadOnly
  case queryForbiddenTable(String)
  case queryResultTooLarge(byteLimit: Int)
  case listingResultTooLarge(byteLimit: Int)
  case unknownRelation(String)
  case templateInvalid(String)
  case importInvalid(String)
  case vocabularyFrozen(String)
  case invalidHandle(String)
  case handleTaken(String)
  case invalidMachineName(String)
  case machineNameTaken(String)
  case unknownDevice(String)
  case invalidDeviceKind(String)
  /// The database predates a schema compaction this binary requires.
  case needsMigration(String)
  /// Admin is held through a personal group, which only a human account has.
  case notAPerson(String)
  /// A personal group's admin edge to itself is what makes it personal.
  case personalGroupEdge(String)
  /// Revoking admin from an account that stays an admin of shared through
  /// another group it belongs to: nothing changed.
  case adminThroughGroup(account: String, groups: [String])
  /// A group the actor's group does not read, named as a new session's home.
  case groupForbidden(String)
  /// A write to a group's instruction layer by someone the layer does not admit.
  case layerForbidden(path: String, group: String)
}

/// Why revoking an account's admin changed nothing: its membership in another
/// group keeps it an admin of shared.
package func adminThroughGroupMessage(_ account: String, _ groups: [String]) -> String {
  let named = groups.count == 1 ? "group \(groups[0])" : "groups \(groups.joined(separator: ", "))"
  return "\(account) stays an admin of shared through its membership in \(named); nothing was changed. "
    + "Revoke that group's admin edge to shared, or remove \(account) from it"
}

extension VersionToken {
  init(rev: Int) {
    self.init(Data(String(rev).utf8))
  }

  var rev: Int? {
    String(data: bytes, encoding: .utf8).flatMap(Int.init)
  }
}
