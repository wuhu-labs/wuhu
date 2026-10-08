import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolbox {
  static let history = SpaceTool("history", schema: HistoryInput.jsonSchema) { (context, input: HistoryInput) in
    let target = try await context.spaceTarget(input.path)
    let entries = try await context.space.history(target.path, in: target.group)
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
    return Wire.object([("entries", .array(payload))])
  }

  static let checkout = SpaceTool("checkout", schema: CheckoutInput.jsonSchema) { (context, input: CheckoutInput) in
    let target = try await context.spaceTarget(input.path)
    try await context.space.refuseLayerWrite(target.path, in: target.group, by: context.principal.actor)
    let (rev, token) = try await context.space.checkout(target.path, rev: Rev(input.rev), in: target.group, acting: context.principal.group)
    return Wire.object([("rev", .integer(rev.value)), ("token", .string(Wire.string(token)))])
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
