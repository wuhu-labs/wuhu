import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolbox {
  static let history = SpaceTool("history", schema: HistoryInput.jsonSchema) { (context, input: HistoryInput) in
    let target = try await context.spaceTarget(input.path)
    let limit = input.limit ?? 100
    guard (1 ... 500).contains(limit), (input.after ?? 0) >= 0 else {
      throw ToolRunError.failed(code: .invalidArgument, message: "history limit must be 1...500 and after non-negative", hint: nil)
    }
    let page = try await context.space.history(target.path, in: target.group, after: input.after, limit: limit + 1)
    let entries = Array(page.prefix(limit))
    let attributions = try await context.space.attributions(of: entries.map(\.0))
    let payload = entries.map { rev, date, change in
      let (kind, to, fromRev): (ChangeKind, String?, Int?) = switch change {
      case .write: (.write, nil, nil)
      case .delete: (.delete, nil, nil)
      case let .move(to): (.move, to, nil)
      case let .checkout(fromRev): (.checkout, nil, fromRev)
      }
      return Wire.object([
        ("rev", .integer(rev.value)),
        ("mtime", .number(date.timeIntervalSince1970)),
        ("change", .string(kind.rawValue)),
        ("to", to.map(JSONValue.string)),
        ("fromRev", fromRev.map(JSONValue.integer)),
        ("by", attributions[rev]?.actor.map(JSONValue.string)),
        ("via", attributions[rev].map { .string($0.via) }),
      ])
    }
    return Wire.object([("entries", .array(payload)), ("next", page.count > limit ? entries.last.map { .integer($0.0.value) } : nil)])
  }

  static let checkout = SpaceTool("checkout", schema: CheckoutInput.jsonSchema) { (context, input: CheckoutInput) in
    try await context.checkout(input.path, rev: input.rev, ifMatch: input.ifMatch)
  }

  static let query = SpaceTool("query", schema: QueryInput.jsonSchema) { (context, input: QueryInput) in
    Wire.queryOutput(try await context.space.query(input.sql, as: context.principal))
  }

  static let tableCreate = SpaceTool("table.create", schema: TableCreateInput.jsonSchema) { (context, input: TableCreateInput) in
    try await context.createTable(input.path, header: input.header)
  }

  static let tableSchema = SpaceTool("table.schema", schema: TableSchemaInput.jsonSchema) { (context, input: TableSchemaInput) in
    try await context.tableSchema(input.path, rev: input.rev)
  }

  static let tableAlter = SpaceTool("table.alter", schema: TableAlterInput.jsonSchema) { (context, input: TableAlterInput) in
    try await context.alterTable(input.path, header: input.header, ifMatch: input.ifMatch, allowDropColumns: input.allowDropColumns ?? false)
  }

  static let tableMutate = SpaceTool("table.mutate", schema: TableMutateInput.jsonSchema) { (context, input: TableMutateInput) in
    let ops = input.ops.map { op -> SpaceCore.RowOp in
      switch op {
      case let .insert(values): .insert(values)
      case let .update(row, values): .update(id: Int64(row), values)
      case let .delete(row): .delete(id: Int64(row))
      }
    }
    let commit = try await context.commitRows(input.path, ops: ops)
    return Wire.object([("rev", .integer(commit.rev.value)), ("ids", .array(commit.ids.map { .integer(Int($0)) }))])
  }

  static let new = SpaceTool("new", schema: NewInput.jsonSchema) { (context, input: NewInput) in
    try await context.instantiateTemplate(input.template, in: input.`in`)
  }
}

public extension SpaceToolContext {
  func checkout(_ address: String, rev: Int, ifMatch: String?, createOnly: Bool = false) async throws(ToolRunError) -> JSONValue {
    do {
      let target = try await spaceTarget(address)
      try await refuseWrite(target.path, in: target.group)
      let (revision, token) = try await space.checkout(target.path, rev: Rev(rev), in: target.group, acting: principal.group, ifMatch: ifMatch.map(Wire.token), createOnly: createOnly)
      return Wire.object([("rev", .integer(revision.value)), ("token", .string(Wire.string(token)))])
    } catch let SpaceError.alreadyExists(path) where createOnly {
      throw .failed(code: .conflict, message: "already exists: \(path)", hint: "Choose another path; create-only operations never replace an existing entry.")
    } catch SpaceError.versionMismatch {
      let target = try? resolve(address)
      let current: VersionToken?
      if let target { current = try? await target.backend.stat(target.path).token }
      else { current = nil }
      throw .failed(code: .conflict, message: "version mismatch: \(address)", hint: Wire.staleHint, token: current.map(Wire.string))
    } catch {
      throw Wire.failure(error)
    }
  }
}
