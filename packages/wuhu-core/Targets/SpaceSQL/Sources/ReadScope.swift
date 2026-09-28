import struct SpaceContract.GroupID

/// What one query may see: the views are bound to `acting`, `readable` and
/// `member`, and `viewer()` answers `viewer` for this query alone.
public struct ReadScope: Hashable, Sendable {
  public let acting: GroupID
  public let readable: Set<GroupID>
  public let viewer: String?
  /// Who reads, as conversations name members: a session id or a persona.
  /// It adds the conversations it is in and the notifications addressed to
  /// it, and narrows `watermarks` to its own; nil (the --dev seat) adds and
  /// narrows nothing.
  public let member: String?

  public init(acting: GroupID, readable: Set<GroupID>, viewer: String? = nil, member: String? = nil) {
    self.acting = acting
    self.readable = readable
    self.viewer = viewer
    self.member = member
  }

  public static func shared(viewer: String? = nil) -> ReadScope {
    ReadScope(acting: .shared, readable: [.shared], viewer: viewer)
  }
}

/// The tables a query may name, each behind a view whose optional filter is
/// the rows of that table the scope may see.
public struct ViewCatalog: Sendable {
  /// One public name: a view of `columns` of `table`, all of them when nil,
  /// holding the rows `filter` admits; or, with `select`, that statement,
  /// reading `table` and `joins`. A filter or statement names a space table
  /// as `{schema}.<table>`.
  struct View: Hashable, Sendable {
    let name: String
    let table: String
    var columns: [String]?
    var filter: String?
    var select: String?
    var joins: [String] = []
  }

  static let schemaPlaceholder = "{schema}"

  static let inducedTables: Set<String> = [
    "docs", "links", "doc_custom_attrs", "sessions", "conversations", "conversation_members",
    "messages", "notifications", "watermarks", "devices", "device_commands",
  ]
  static let groupedTables: Set<String> = ["docs", "links", "doc_custom_attrs", "sessions", "conversations", "notifications"]
  // SQLite reports a table-valued function as a read of a table by its name;
  // these two read nothing but their own arguments.
  static let tableFunctions: Set<String> = ["json_each", "json_tree"]

  let views: @Sendable (_ tables: [String: [String]], _ scope: ReadScope) -> [View]

  init(views: @escaping @Sendable (_ tables: [String: [String]], _ scope: ReadScope) -> [View]) {
    self.views = views
  }

  // Every materialized table is named by its quoted space path, which always
  // starts with "/"; substrate tables never do.
  public init(filter: @escaping @Sendable (_ table: String, _ scope: ReadScope) -> String? = { _, _ in nil }) {
    views = { tables, scope in
      tables.keys.filter { Self.inducedTables.contains($0) || $0.hasPrefix("/") }.sorted().map {
        View(name: $0, table: $0, filter: filter($0, scope))
      }
    }
  }

  public static let identity: ViewCatalog = ViewCatalog()

  /// The grouped space: an unqualified name reads the acting group,
  /// `wuhu://<g>.localspace/<name>` a readable group `g`, and
  /// `wuhu://*.localspace/<name>` every readable group with a `grp` column.
  /// A user table `"<g>:/x.table"` is `"/x.table"` in `g` and
  /// `"wuhu://<g>.localspace/x.table"` wherever `g` is readable.
  public static let groups: ViewCatalog = ViewCatalog(views: groupViews)

  static func groupViews(_ tables: [String: [String]], _ scope: ReadScope) -> [View] {
    let acting = scope.acting.rawValue
    let readable = scope.readable.map(\.rawValue).reduce(into: Set([acting])) { $0.insert($1) }
    let literal = { (text: String) in "'" + text.replacing("'", with: "''") + "'" }
    let s = schemaPlaceholder
    // The acting group's conversations and the ones the reader is in.
    let visible = "grp = \(literal(acting))" + (scope.member.map {
      " OR id IN (SELECT conversation_id FROM \(s).\"conversation_members\" WHERE member = \(literal($0)))"
    } ?? "")
    let inVisible = "conversation_id IN (SELECT id FROM \(s).\"conversations\" WHERE \(visible))"
    let everyReadable = "grp IN (" + readable.sorted().map(literal).joined(separator: ", ") + ")"
    var views: [View] = []
    for (table, columns) in tables.sorted(by: { $0.key < $1.key }) {
      if let colon = table.firstIndex(of: ":"), table[table.index(after: colon)...].hasPrefix("/") {
        let group = String(table[..<colon])
        let path = String(table[table.index(after: colon)...])
        if group == acting { views.append(View(name: path, table: table)) }
        if readable.contains(group) { views.append(View(name: "wuhu://\(group).localspace\(path)", table: table)) }
      } else if groupedTables.contains(table) {
        let own = columns.filter { $0 != "grp" }
        let unqualified = switch table {
        case "links":
          View(name: table, table: table, columns: own.filter { $0 != "dst_grp" }, filter: "grp = \(literal(acting)) AND dst_grp = \(literal(acting))")
        case "conversations":
          View(name: table, table: table, columns: own, filter: visible, joins: ["conversation_members"])
        case "notifications":
          View(
            name: table, table: table, columns: own,
            filter: "grp = \(literal(acting))" + (scope.member.map { " OR recipient = \(literal($0))" } ?? ""),
          )
        default:
          View(name: table, table: table, columns: own, filter: "grp = \(literal(acting))")
        }
        views.append(unqualified)
        for group in readable.sorted() {
          views.append(View(name: "wuhu://\(group).localspace/\(table)", table: table, columns: own, filter: "grp = \(literal(group))"))
        }
        views.append(View(name: "wuhu://*.localspace/\(table)", table: table, columns: ["grp"] + own, filter: everyReadable))
      } else if table == "messages" || table == "conversation_members" {
        views.append(View(name: table, table: table, filter: inVisible, joins: ["conversations", "conversation_members"]))
        if table == "messages" {
          views.append(View(
            name: "message_senders", table: table,
            select: """
            SELECT m.n AS n, m.sender_session_id AS sender_session_id,
              COALESCE(g.grp, se.grp, c.grp) AS sender_grp, se.title AS sender_title
            FROM \(s)."messages" m
            LEFT JOIN \(s)."message_groups" g ON g.message_id = m.id
            LEFT JOIN \(s)."sessions" se ON se.id = m.sender_session_id
            LEFT JOIN \(s)."conversations" c ON c.id = m.conversation_id
            WHERE m.\(inVisible)
            """,
            joins: ["message_groups", "sessions", "conversations", "conversation_members"],
          ))
        }
      } else if table == "watermarks" {
        views.append(View(name: table, table: table, filter: scope.member.map { "identity = \(literal($0))" }))
      } else if inducedTables.contains(table) {
        views.append(View(name: table, table: table))
      } else if table == "groups" {
        views.append(View(name: table, table: table, columns: ["id", "created_at"], filter: "removed_at IS NULL"))
      } else if table == "group_reads" {
        views.append(View(name: table, table: table, columns: ["readable", "via"], filter: "grp = \(literal(acting))"))
      }
    }
    return views
  }
}
