import DocIndex
import struct Foundation.Data
import JSONValue
import OrderedCollections
import SpaceContract
import SpaceCore
import SpaceFS

// The data verbs pages and scripts share: typed reads, named row
// edits, and frontmatter attributes. Each takes a path by the one rule, a
// hostless path in the acting group or `wuhu://<group>.localspace/…`.
extension SpaceToolContext {
  /// `sql` with typed parameters, in the typed rule.
  public func typedQuery(_ sql: String, parameters: [JSONValue]) async throws -> JSONValue {
    Wire.typedQueryOutput(try await space.query(sql, parameters: parameters, as: principal))
  }

  /// Named-field row ops in one revision, returning it and the inserted ids.
  public func commitRows(_ address: String, edits: [RowEdit]) async throws -> RowCommit {
    let target = try await spaceTarget(address)
    try await refuseWrite(target.path, in: target.group)
    return try await space.commitRows(
      target.path, edits: edits, in: target.group, acting: principal.group, attribution: attribution,
    )
  }

  /// The top-level frontmatter keys of a Markdown file, from its source, and
  /// the version they were read at.
  public func readAttributes(_ address: String) async throws -> (attributes: OrderedDictionary<String, JSONValue>, token: VersionToken) {
    let target = try await spaceTarget(address)
    try requireMarkdown(target.path)
    let (token, data) = try await space.fs(target.group).read(target.path.rawValue)
    return (try Frontmatter.attributes(of: data), token)
  }

  /// Sets and removes top-level frontmatter keys of the version `ifMatch`
  /// names, keeping every other byte; a stale `ifMatch` is a conflict that
  /// carries the current token.
  public func patchAttributes(
    _ address: String, set: OrderedDictionary<String, JSONValue>, remove: [String], ifMatch: String,
  ) async throws -> VersionToken {
    let target = try await spaceTarget(address)
    try requireMarkdown(target.path)
    try await refuseWrite(target.path, in: target.group)
    let fs = await space.fs(target.group, acting: principal.group, attribution: attribution)
    let path = target.path.rawValue
    let (token, data) = try await fs.read(path)
    guard Wire.string(token) == ifMatch else { throw Self.conflict(address, current: token) }
    let patched = try Frontmatter.patch(data, set: set, remove: remove)
    do {
      return try await fs.write(path, patched, ifMatch: token)
    } catch SpaceError.versionMismatch {
      throw Self.conflict(address, current: try await fs.read(path).0)
    }
  }

  private func requireMarkdown(_ path: SpacePath) throws {
    guard path.lastComponent?.lowercased().hasSuffix(".md") == true else {
      throw ToolRunError.failed(
        code: .invalidArgument, message: "attributes live in a Markdown file's frontmatter: \(path.rawValue) is not a .md file",
        hint: nil,
      )
    }
  }

  private static func conflict(_ address: String, current: VersionToken) -> ToolRunError {
    .failed(code: .conflict, message: "version mismatch: \(address)", hint: Wire.staleHint, token: Wire.string(current))
  }
}

extension SpaceToolbox {
  static let attributesRead = SpaceTool("attributes.read", schema: AttributesReadInput.jsonSchema) { (context, input: AttributesReadInput) in
    let (attributes, token) = try await context.readAttributes(input.path)
    return Wire.object([("attributes", .object(attributes)), ("token", .string(Wire.string(token)))])
  }

  static let attributesPatch = SpaceTool("attributes.patch", schema: AttributesPatchInput.jsonSchema) { (context, input: AttributesPatchInput) in
    let set: OrderedDictionary<String, JSONValue>
    switch input.set {
    case nil: set = [:]
    case let .object(fields)?: set = fields
    case .some:
      throw ToolRunError.failed(code: .invalidArgument, message: "attributes.patch: set must be an object of top-level keys", hint: nil)
    }
    let token = try await context.patchAttributes(input.path, set: set, remove: input.remove ?? [], ifMatch: input.ifMatch)
    return Wire.object([("token", .string(Wire.string(token)))])
  }
}

extension RowEdit {
  /// Named-field ops in the wire shape `wuhu:space` sends: `{insert: {…}}`,
  /// `{update: id, set: {…}}` or `{delete: id}`, nothing else.
  public static func parse(_ ops: JSONValue) throws(ToolRunError) -> [RowEdit] {
    guard case let .array(items) = ops else { throw invalid("ops must be an array") }
    var edits: [RowEdit] = []
    var touched: [Int64: Int] = [:]
    for (index, item) in items.enumerated() {
      let what = "ops[\(index)]"
      guard case let .object(op) = item else { throw invalid("\(what) must be an object") }
      let keys = Set(op.keys)
      let edit: RowEdit
      if keys == ["insert"], case let .object(fields)? = op["insert"] {
        edit = .insert(fields)
      } else if keys == ["update", "set"], let id = rowID(op["update"]), case let .object(fields)? = op["set"] {
        edit = .update(id: id, fields)
      } else if keys == ["delete"], let id = rowID(op["delete"]) {
        edit = .delete(id: id)
      } else {
        throw invalid("\(what) must be {insert: {…}}, {update: id, set: {…}} or {delete: id}")
      }
      if let id = edit.rowID {
        if let first = touched[id] {
          throw invalid("ops[\(first)] and \(what) both touch row \(id); one call touches each row at most once, so merge its fields into one update")
        }
        touched[id] = index
      }
      edits.append(edit)
    }
    return edits
  }

  private var rowID: Int64? {
    switch self {
    case .insert: nil
    case let .update(id, _), let .delete(id): id
    }
  }

  private static func rowID(_ value: JSONValue?) -> Int64? {
    switch value {
    case let .integer(id)?: Int64(id)
    case let .number(id)? where id.rounded() == id && abs(id) <= 9_007_199_254_740_991: Int64(id)
    default: nil
    }
  }

  private static func invalid(_ message: String) -> ToolRunError {
    .failed(code: .invalidArgument, message: message, hint: nil)
  }
}
