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
    let target = try await context.spaceTarget(input.path)
    let rev = try await context.space.createTable(target.path, header: header(input.header), in: target.group, acting: context.principal.group)
    return Wire.object([("rev", .integer(rev.value))])
  }

  static let tableAlter = SpaceTool("table.alter", schema: TableAlterInput.jsonSchema) { (context, input: TableAlterInput) in
    let target = try await context.spaceTarget(input.path)
    let rev = try await context.space.alterTable(target.path, header: header(input.header), in: target.group, acting: context.principal.group)
    return Wire.object([("rev", .integer(rev.value))])
  }

  static let tableMutate = SpaceTool("table.mutate", schema: TableMutateInput.jsonSchema) { (context, input: TableMutateInput) in
    let ops = input.ops.map { op -> SpaceCore.RowOp in
      switch op {
      case let .insert(values): .insert(values)
      case let .update(row, values): .update(id: Int64(row), values)
      case let .delete(row): .delete(id: Int64(row))
      }
    }
    let target = try await context.spaceTarget(input.path)
    let commit = try await context.space.commitRows(target.path, ops, in: target.group, acting: context.principal.group)
    return Wire.object([("rev", .integer(commit.rev.value)), ("ids", .array(commit.ids.map { .integer(Int($0)) }))])
  }

  static let new = SpaceTool("new", schema: NewInput.jsonSchema) { (context, input: NewInput) in
    let template = try await context.spaceTarget(input.template)
    var destination: (group: GroupID, path: SpacePath, qualified: Bool)?
    if let raw = input.`in` { destination = try await context.spaceTarget(raw) }
    try await context.space.refuseLayerWrite(
      destination?.path ?? template.path.parent, in: destination?.group ?? template.group, by: context.principal.actor,
    )
    let created = try await context.space.instantiate(
      template: template.path, of: template.group,
      in: destination?.path, of: destination?.group ?? template.group,
      acting: context.principal.group,
    )
    let (group, qualified) = destination.map { ($0.group, $0.qualified) } ?? (template.group, template.qualified)
    return Wire.object([("path", .string(qualified ? FSResolver.address(created.rawValue, inGroup: group.rawValue) : created.rawValue))])
  }
}

private func header(_ header: SpaceContract.TableHeader) -> SpaceCore.TableHeader {
  SpaceCore.TableHeader(columns: header.columns.map { column in
    let type: TableColumn.ColumnType = switch column.type {
    case .string: .text
    case .integer: .integer
    case .number: .real
    case .boolean: .boolean
    case .json: .json
    }
    return TableColumn(name: column.name, type: type)
  })
}
