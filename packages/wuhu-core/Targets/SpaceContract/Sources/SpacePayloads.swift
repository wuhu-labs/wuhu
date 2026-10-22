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
  public let after: Int?
  public let limit: Int?
}

@Contract
public struct HistoryOutput: Codable, Equatable, Sendable {
  public let entries: [HistoryEntry]
  public let next: Int?
}

@Contract
public struct CheckoutInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int
  public let ifMatch: String?
  /// With no `ifMatch`, restore only a path that is missing now.
  public let createOnly: Bool?
}

@Contract
public struct CheckoutOutput: Codable, Equatable, Sendable {
  public let rev: Int
  public let token: String
}

@Contract
public struct QueryInput: Codable, Equatable, Sendable {
  public let sql: String
  /// Bound in order of the statement's `?` placeholders.
  public let parameters: [JSONValue]?
  /// The typed rule: a json column's value arrives as `{"json": v}`, a blob as
  /// `{"blob": base64}`, so a client can tell them from text.
  public let typed: Bool?
  /// Refuse a result larger than this many bytes (capped by the tool's own bound).
  public let byteLimit: Int?
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
  public let ifMatch: String
  public let allowDropColumns: Bool?
}

@Contract
public struct TableSchemaInput: Codable, Equatable, Sendable {
  public let path: String
  public let rev: Int?
}

@Contract
public struct TableSchemaOutput: Codable, Equatable, Sendable {
  public let header: TableHeader
  public let token: String
}

@Contract
public struct TableWriteOutput: Codable, Equatable, Sendable {
  public let rev: Int
  public let token: String
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

/// Named-field row ops, the shape `wuhu:space`'s `mutateRows` sends from a
/// page or a script: `{insert: {…}}`, `{update: id, set: {…}}` or `{delete: id}`.
@Contract
public struct TableRowsInput: Codable, Equatable, Sendable {
  public let path: String
  public let ops: JSONValue
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
  /// The server's clock when it answered, Unix epoch seconds: the time a client signs its assertions by.
  public let now: Double?
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
/// flags are nil from a server that predates them.
@Contract
public struct GroupSummary: Codable, Equatable, Sendable {
  public let id: String
  /// The caller writes here: an open group, or one listing its group or its account.
  public let member: Bool?
  /// The caller reads this group.
  public let readable: Bool?
  /// The caller administers this group: the rule `is_admin` uses.
  public let admin: Bool?
}

/// One entry of a private group's list.
@Contract
public struct GroupAccessEntry: Codable, Equatable, Sendable {
  /// `account` or `group`.
  public let kind: String
  public let id: String
  /// `read`, `write` or `admin`.
  public let role: String
}

/// A group as its admin sees it.
@Contract
public struct GroupDetail: Codable, Equatable, Sendable {
  public let id: String
  public let alias: String?
  public let open: Bool
  public let secrets: String
  public let personal: Bool
  public let entries: [GroupAccessEntry]
}

@Contract
public struct GroupUpdateInput: Codable, Equatable, Sendable {
  public let alias: String?
  public let open: Bool?
  /// `owner` or `reachable`.
  public let secrets: String?
}

@Contract
public struct GroupAccessInput: Codable, Equatable, Sendable {
  /// `account` or `group`.
  public let kind: String
  public let id: String
  /// `read`, `write` or `admin`.
  public let role: String
}

@Contract
public struct GroupCreateInput: Codable, Equatable, Sendable {
  public let alias: String
  public let owner: String?
}

/// The request header that names the group a person's request acts in.
public enum GroupHeader {
  public static let name: String = "wuhu-group"
  /// The `ServerInfo.features` entry of a server that understands the header.
  public static let feature: String = "groups"
}

/// The request header that names the session tool call a `/v1/tools/<name>`
/// request runs for: the server answers a repeat of the same call with the
/// first successful response instead of running the tool again.
public enum ToolCallHeader {
  public static let name: String = "wuhu-tool-call"
}

@Contract
public enum ObserveInput: Codable, Equatable, Sendable {
  case glob(pattern: String, from: Int?, batch: Bool? = nil)
  case sql(query: String, throttleMs: Int?)
}
