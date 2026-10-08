import Foundation
import JSONValue
import SpaceContract
import SpaceToolReference
import SpaceTools
import Testing

// Every tool output is validated structurally against the contract schema its
// reference page names (the same registry the checked-in fixtures are
// golden-pinned to), so an extra or typo'd key in a wire payload fails here
// instead of shipping.
@Suite struct SchemaShapeTests {
  static let samples: [(tool: String, input: JSONValue)] = [
    ("write", .object(["path": "/notes/a.md", "content": "foo [b](/b.md)\nbar"])),
    ("read", .object(["path": "/notes/a.md"])),
    ("edit", .object(["path": "/notes/a.md", "edits": .array([.object(["old": "bar", "new": "baz"])])])),
    ("ls", .object(["path": "/"])),
    ("stat", .object(["path": "/notes/a.md"])),
    ("grep", .object(["pattern": "o", "matchLimit": 1])),
    ("find", .object(["glob": "/**"])),
    ("table.create", .object([
      "path": "/data/t.table",
      "header": .object(["columns": .array([
        .object(["name": "n", "type": "integer"]),
        .object(["name": "j", "type": "json"]),
        .object(["name": "b", "type": "boolean"]),
      ])]),
    ])),
    ("table.schema", ["path": "/data/t.table"]),
    ("table.alter", .object([
      "path": "/data/t.table",
      "header": .object(["columns": .array([
        .object(["name": "n", "type": "integer"]),
        .object(["name": "j", "type": "json"]),
        .object(["name": "b", "type": "boolean"]),
        .object(["name": "s", "type": "string"]),
      ])]),
    ])),
    ("table.mutate", .object([
      "path": "/data/t.table",
      "ops": .array([.object([
        "kind": "insert",
        "values": .array([.integer(7), .object(["k": "v"]), .bool(true), .string("s")]),
      ])]),
    ])),
    ("query", .object(["sql": "SELECT n, j, b FROM \"/data/t.table\""])),
    ("checkout", .object(["path": "/notes/a.md", "rev": 1])),
    ("mv", .object(["from": "/b.md", "to": "/c.md"])),
    ("history", .object(["path": "/notes/a.md"])),
    ("rm", .object(["path": "/c.md"])),
    ("new", .object(["template": "/templates/j.md", "in": "/journal"])),
    ("attributes.read", .object(["path": "/templates/j.md"])),
  ]

  @Test func everyToolOutputMatchesItsContractSchema() async throws {
    let context = try makeContext()
    _ = try await seedFile("/b.md", "target", context)
    _ = try await seedFile("/templates/j.md", "---\ntemplate:\n  strategy: incr\n  prefix: J\n---\nhi", context)

    var validated = Set<String>()
    let syncBase = try await seedFile("/sync.md", "before", context)
    let syncSchema = try outputSchema("sync")
    let syncOutput = try await run(
      "sync",
      .object(["path": "/sync.md", "baseToken": .string(syncBase.token), "content": "after"]),
      context,
    )
    #expect(schemaIssues(syncOutput, schema: syncSchema) == [], "sync")
    validated.insert("sync")
    for (tool, input) in Self.samples {
      let schema = try outputSchema(tool)
      var input = input
      if tool == "table.alter", case var .object(fields) = input {
        fields["ifMatch"] = try await run("table.schema", ["path": "/data/t.table"], context).object?["token"]
        input = .object(fields)
      }
      let output = try await run(tool, input, context)
      #expect(schemaIssues(output, schema: schema) == [], "\(tool)")
      validated.insert(tool)
    }
    let attributes = try await run("attributes.read", ["path": "/sync.md"], context, as: AttributesReadOutput.self)
    let patched = try await run("attributes.patch", ["path": "/sync.md", "set": ["k": 1], "ifMatch": .string(attributes.token)], context)
    let patchSchema = try outputSchema("attributes.patch")
    #expect(schemaIssues(patched, schema: patchSchema) == [], "attributes.patch")
    validated.insert("attributes.patch")
    #expect(validated == Set(SpaceToolbox.all.map(\.name)))
  }

  @Test func provenanceHistoryEntriesMatchTheSchema() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)
    _ = try await run("checkout", .object(["path": "/a.md", "rev": .integer(first.rev!)]), context)
    _ = try await run("mv", .object(["from": "/a.md", "to": "/z.md"]), context)

    let schema = try outputSchema("history")
    let output = try await run("history", .object(["path": "/a.md"]), context)
    #expect(schemaIssues(output, schema: schema) == [])
  }
}

// The output schema the tool's reference page names, so the pages cannot
// promise a shape the tool does not answer.
private func outputSchema(_ tool: String) throws -> JSONValue {
  let name = try #require(ToolReference.entries.first { $0.tool == tool }?.output, "no reference entry for \(tool)")
  return try #require(ContractSchemas.all.first { $0.name == name }?.schema, "no schema named \(name)")
}

func schemaIssues(_ value: JSONValue, schema: JSONValue, at path: String = "$") -> [String] {
  guard let spec = schema.object else { return ["\(path): schema is not an object"] }
  if spec.isEmpty { return [] }
  if let oneOf = spec["oneOf"]?.array {
    let passing = oneOf.count { schemaIssues(value, schema: $0, at: path).isEmpty }
    return passing == 1 ? [] : ["\(path): matches \(passing) oneOf branches"]
  }

  var issues: [String] = []
  if let constant = spec["const"], value != constant {
    issues.append("\(path): expected const \(constant.jsonString())")
  }
  if let allowed = spec["enum"]?.array, !allowed.contains(value) {
    issues.append("\(path): \(value.jsonString()) not in enum")
  }
  if let type = spec["type"] {
    let names = type.array?.compactMap(\.stringValue) ?? type.stringValue.map { [$0] } ?? []
    if !names.contains(where: { typeMatches(value, $0) }) {
      issues.append("\(path): \(value.jsonString()) does not match type \(names)")
    }
  }
  if case let .object(fields) = value {
    let properties = spec["properties"]?.object ?? [:]
    for name in spec["required"]?.array?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
      issues.append("\(path): missing required key \"\(name)\"")
    }
    for (name, field) in fields {
      guard let property = properties[name] else {
        issues.append("\(path): unexpected key \"\(name)\"")
        continue
      }
      issues += schemaIssues(field, schema: property, at: "\(path).\(name)")
    }
  }
  if case let .array(elements) = value, let items = spec["items"] {
    for (index, element) in elements.enumerated() {
      issues += schemaIssues(element, schema: items, at: "\(path)[\(index)]")
    }
  }
  return issues
}

private func typeMatches(_ value: JSONValue, _ type: String) -> Bool {
  switch (type, value) {
  case ("object", .object), ("array", .array), ("string", .string),
       ("integer", .integer), ("number", .number), ("number", .integer),
       ("boolean", .bool), ("null", .null):
    true
  default:
    false
  }
}
