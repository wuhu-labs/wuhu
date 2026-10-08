import Contract
import JSONValue

@Contract
public enum ChangeKind: String, Codable, Equatable, Sendable {
  case write
  case delete
  case move
  case checkout
}

@Contract
public struct HistoryEntry: Codable, Equatable, Sendable {
  public let rev: Int
  public let mtime: Double
  public let change: ChangeKind
  public let to: String?
  public let fromRev: Int?
  /// For a revision a page wrote: the viewer's persona (absent for the
  /// --dev seat) and the page's path.
  public let by: String?
  public let via: String?
}

@Contract
public struct HistoryInput: Codable, Equatable, Sendable {
  public let path: String
}

@Contract
public struct HistoryOutput: Codable, Equatable, Sendable {
  public let entries: [HistoryEntry]
}

@Contract
public struct CheckoutInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int
}

@Contract
public struct CheckoutOutput: Codable, Equatable, Sendable {
  public let rev: Int
  public let token: String
}

@Contract
public struct QueryInput: Codable, Equatable, Sendable {
  public let sql: String
}

@Contract
public struct QueryOutput: Codable, Equatable, Sendable {
  public let columns: [String]
  public let rows: [[JSONValue]]
}

@Contract
public struct TableCreateInput: Codable, Equatable, Sendable {
  public let path: String
  public let header: TableHeader
}

@Contract
public struct TableAlterInput: Codable, Equatable, Sendable {
  public let path: String
  public let header: TableHeader
}

@Contract
public struct TableMutateInput: Codable, Equatable, Sendable {
  public let path: String
  public let ops: [RowOp]
}

@Contract
public struct TableMutateOutput: Codable, Equatable, Sendable {
  public let rev: Int
  /// The inserted row ids, in op order.
  public let ids: [Int]
}

@Contract
public struct AttributesReadInput: Codable, Equatable, Sendable {
  public let path: String
}

@Contract
public struct AttributesReadOutput: Codable, Equatable, Sendable {
  /// The top-level frontmatter keys, read from the source YAML.
  public let attributes: JSONValue
  public let token: String
}

@Contract
public struct AttributesPatchInput: Codable, Equatable, Sendable {
  public let path: String
  /// Top-level keys to set, an object.
  public let set: JSONValue?
  public let remove: [String]?
  /// The token `attributes.read` gave; a stale one is a conflict carrying the current token.
  public let ifMatch: String
}

@Contract
public struct AttributesPatchOutput: Codable, Equatable, Sendable {
  public let token: String
}

@Contract
public struct NewInput: Codable, Equatable, Sendable {
  public let template: String
  public let `in`: String?
}

@Contract
public struct NewOutput: Codable, Equatable, Sendable {
  public let path: String
}

@Contract
public struct ServerInfo: Codable, Equatable, Sendable {
  public let space: String?
  public let origin: String?
  /// Without `contentHost`, a group's content origin is `https://<group>.<contentBase>`, `shared` included.
  public let contentBase: String?
  /// A flat-host server's template authority, such as `{group}--alex.example`: a group's content origin is
  /// `https://` and the template with `{group}` replaced by the group, `shared` included. Such a server omits
  /// `contentBase`; when both are present, `contentHost` applies.
  public let contentHost: String?
  public let features: [String]?
  public let aiDisclosure: AIDisclosure?
  /// The group the caller acts in: its `Wuhu-Group` header, else the server's default for it.
  public let group: String?
}

@Contract
public struct AIDisclosure: Codable, Equatable, Sendable {
  public let version: String
  public let providers: [AIProviderDisclosure]
}

@Contract
public struct AIProviderDisclosure: Codable, Equatable, Sendable {
  public let name: String
  public let location: String
  public let via: String
  public let policy: String
}

/// A group as the caller stands to it, whatever group the request names. The
/// two flags are nil from a server that predates them.
@Contract
public struct GroupSummary: Codable, Equatable, Sendable {
  public let id: String
  /// The caller acts and creates here: a person's membership, a session's own group.
  public let member: Bool?
  /// Some group the caller is a member of reads this one.
  public let readable: Bool?
}

/// `PUT /v1/groups/:id`: the settings to change; a missing one stays.
public struct GroupUpdateInput: Codable, Equatable, Sendable {
  /// Whether the group's sessions render the space-wide instruction layer.
  public let spaceLayer: Bool?

  public init(spaceLayer: Bool?) {
    self.spaceLayer = spaceLayer
  }
}

/// A group's settings, as `PUT /v1/groups/:id` leaves them.
public struct GroupSettings: Codable, Equatable, Sendable {
  public let id: String
  public let spaceLayer: Bool

  public init(id: String, spaceLayer: Bool) {
    self.id = id
    self.spaceLayer = spaceLayer
  }
}

/// The request header that names the group a person's request acts in.
public enum GroupHeader {
  public static let name: String = "wuhu-group"
  /// The `ServerInfo.features` entry of a server that understands the header.
  public static let feature: String = "groups"
}

@Contract
public enum ObserveInput: Codable, Equatable, Sendable {
  case glob(pattern: String, from: Int?)
  case sql(query: String, throttleMs: Int?)
}
