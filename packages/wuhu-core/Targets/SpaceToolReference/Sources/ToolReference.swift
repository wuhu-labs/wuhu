import Contract
import JSONValue
import SpaceContract
import SpaceTools

// The reference page of every space tool, derived from the toolbox and the
// contract schemas. contract-export writes the pages into `directory`, and a
// golden test fails until the checked-in pages match.
public enum ToolReference {
  public struct Entry: Sendable {
    public let tool: String
    public let input: String
    public let output: String
    public let summary: String
  }

  public static let directory: String = "packages/wuhu-core/Targets/SpaceToolReference/Tests/reference"

  // From a page to the schema files, both under packages/wuhu-core/Targets.
  static let schemaDirectory: String = "../../../SpaceContract/Tests/contract"

  public static let entries: [Entry] = [
    Entry(
      tool: "read", input: "ReadInput", output: "ReadOutput",
      summary: "Read a file's UTF-8 text, at the head or at a past revision `rev`. `lines` (`A-B`, 1-based, inclusive) cuts a range. A file that is not UTF-8 text is `unsupported`.",
    ),
    Entry(
      tool: "write", input: "WriteInput", output: "WriteOutput",
      summary: "Create or replace a file with UTF-8 text. With `ifMatch`, the write succeeds only if the file is still at that version token.",
    ),
    Entry(
      tool: "edit", input: "EditInput", output: "EditOutput",
      summary: "Apply exact text replacements in order. Each `old` must occur exactly once in the text as the earlier edits left it; otherwise nothing is written.",
    ),
    Entry(
      tool: "sync", input: "SyncInput", output: "SyncOutput",
      summary: "Save a full-text draft of a file read at `baseToken`. The answer's `kind` says whether the draft was `saved` as is, `merged` with the changes made since, or hit a `conflict`, in which case nothing is written.",
    ),
    Entry(
      tool: "rm", input: "RemoveInput", output: "RevisionOutput",
      summary: "Remove a path. With `ifMatch`, only if it is still at that version token.",
    ),
    Entry(
      tool: "mv", input: "MoveInput", output: "MoveOutput",
      summary: "Move a path. An existing `to` refuses the move unless `replace` is true. `dangling` lists the documents whose links still point at the old path.",
    ),
    Entry(
      tool: "ls", input: "ListInput", output: "ListOutput",
      summary: "List a folder's entries, at the head or at `rev`. At `/` the system folder `/_` and `/users` are left out unless `hidden` is true.",
    ),
    Entry(
      tool: "stat", input: "StatInput", output: "Entry",
      summary: "One path's metadata: kind, size, line count, version token and modification time.",
    ),
    Entry(
      tool: "grep", input: "GrepInput", output: "GrepOutput",
      summary: "Search file contents under `path` (default `/`) for a regular expression. A non-null `cursor` in the answer is the `step` that continues the search.",
    ),
    Entry(
      tool: "find", input: "FindInput", output: "FindOutput",
      summary: "Find paths under `path` (default `/`) matching a glob, paged like `grep`.",
    ),
    Entry(
      tool: "history", input: "HistoryInput", output: "HistoryOutput",
      summary: "A path's revisions, oldest first: what each changed and, where recorded, who made it.",
    ),
    Entry(
      tool: "checkout", input: "CheckoutInput", output: "CheckoutOutput",
      summary: "Restore a path's content from revision `rev` as a new revision. History never rewinds.",
    ),
    Entry(
      tool: "query", input: "QueryInput", output: "QueryOutput",
      summary: "Run a read-only `SELECT` over the space's tables and induced tables.",
    ),
    Entry(
      tool: "table.create", input: "TableCreateInput", output: "RevisionOutput",
      summary: "Create a table at a `.table` path with the given columns.",
    ),
    Entry(
      tool: "table.alter", input: "TableAlterInput", output: "RevisionOutput",
      summary: "Replace a table's header.",
    ),
    Entry(
      tool: "table.mutate", input: "TableMutateInput", output: "TableMutateOutput",
      summary: "Insert, update and delete rows in one revision. `values` follow the header's column order; `ids` are the inserted rows' ids.",
    ),
    Entry(
      tool: "new", input: "NewInput", output: "NewOutput",
      summary: "Instantiate a template document, next to it or in the folder `in`, and answer the new path.",
    ),
    Entry(
      tool: "attributes.read", input: "AttributesReadInput", output: "AttributesReadOutput",
      summary: "Read a Markdown file's frontmatter as an object, with the version token `attributes.patch` takes.",
    ),
    Entry(
      tool: "attributes.patch", input: "AttributesPatchInput", output: "AttributesPatchOutput",
      summary: "Set and remove top-level frontmatter keys of a Markdown file, keeping the rest of its YAML. A stale `ifMatch` is `conflict`, carrying the current `token`.",
    ),
  ]

  public static func pages() -> [(fileName: String, content: String)] {
    let entries = SpaceToolbox.all.map { tool in
      guard let entry = Self.entries.first(where: { $0.tool == tool.name }) else {
        preconditionFailure("no reference entry for the \(tool.name) tool")
      }
      return entry
    }
    return [("README.md", index(entries))] + entries.map { ("\($0.tool).md", page($0)) }
  }

  static func schema(named name: String) -> JSONValue {
    guard let schema = ContractSchemas.all.first(where: { $0.name == name })?.schema else {
      preconditionFailure("no contract schema named \(name)")
    }
    return schema
  }

  static func link(_ type: String) -> String {
    "[`\(type)`](\(schemaDirectory)/\(SchemaDocument.fileName(forType: type)))"
  }

  static let footer = """
  Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.

  """

  static func index(_ entries: [Entry]) -> String {
    var lines = [
      "# Space tools",
      "",
      "Each tool is one route, `POST /v1/tools/<name>`, taking the tool's input as its JSON body and answering its output. The CLI, the web app and the server's own agents all go through these tools.",
      "",
      "| Tool | Input | Output |",
      "| --- | --- | --- |",
    ]
    for entry in entries {
      lines.append("| [`\(entry.tool)`](\(entry.tool).md) | \(link(entry.input)) | \(link(entry.output)) |")
    }
    lines += ["", errors, "", footer]
    return lines.joined(separator: "\n")
  }

  static let errors = """
  A refusal answers a \(link("ToolError")) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.
  """

  static func page(_ entry: Entry) -> String {
    var lines = [
      "# `\(entry.tool)`",
      "",
      entry.summary,
      "",
      "`POST /v1/tools/\(entry.tool)` takes a \(link(entry.input)) body and answers `200` with a \(link(entry.output)).",
      "",
      "## Input",
      "",
    ]
    lines += table(schema(named: entry.input))
    lines += ["", "## Output", ""]
    lines += table(schema(named: entry.output))
    lines += ["", "## Errors", "", errors, "", footer]
    return lines.joined(separator: "\n")
  }

  struct Row {
    let field: String
    let type: String
    let required: Bool
    var when: String?
  }

  static func table(_ schema: JSONValue) -> [String] {
    let fields = rows(schema, prefix: "")
    if fields.isEmpty { return ["An empty object."] }
    let required = { (row: Row) in row.required ? "yes" : "no" }
    guard fields.contains(where: { $0.when != nil }) else {
      return ["| Field | Type | Required |", "| --- | --- | --- |"]
        + fields.map { "| `\($0.field)` | \($0.type) | \(required($0)) |" }
    }
    return ["| Field | Type | Required | When |", "| --- | --- | --- | --- |"]
      + fields.map { "| `\($0.field)` | \($0.type) | \(required($0)) | \($0.when ?? "always") |" }
  }

  // An object's fields, then a nested object's as `parent.child` and an array
  // of objects' as `parent[].child`. The branches of a oneOf share one row for
  // the `kind` constant that tells them apart, and every other field of a
  // branch says which kind it belongs to.
  static func rows(_ schema: JSONValue, prefix: String) -> [Row] {
    guard let spec = schema.object else { return [] }
    if let branches = spec["oneOf"]?.array {
      let kinds = branches.compactMap { $0.object?["properties"]?.object?["kind"]?.object?["const"] }
      guard kinds.count == branches.count else {
        return branches.enumerated().flatMap { index, branch in
          rows(branch, prefix: prefix).map { row in
            var row = row
            row.when = row.when ?? "variant \(index + 1)"
            return row
          }
        }
      }
      let head = Row(field: prefix + "kind", type: "one of " + kinds.map { "`\($0.jsonString())`" }.joined(separator: ", "), required: true)
      return [head] + zip(branches, kinds).flatMap { branch, kind in
        rows(branch, prefix: prefix).filter { $0.field != head.field }.map { row in
          var row = row
          row.when = row.when ?? "`kind` is `\(kind.jsonString())`"
          return row
        }
      }
    }
    let required = Set(spec["required"]?.array?.compactMap(\.stringValue) ?? [])
    var result: [Row] = []
    for (name, property) in spec["properties"]?.object ?? [:] {
      let field = prefix + name
      result.append(Row(field: field, type: describe(property), required: required.contains(name)))
      if property.object?["properties"] != nil || property.object?["oneOf"] != nil {
        result += rows(property, prefix: field + ".")
      } else if let items = property.object?["items"], items.object?["properties"] != nil || items.object?["oneOf"] != nil {
        result += rows(items, prefix: field + "[].")
      }
    }
    return result
  }

  static func describe(_ schema: JSONValue) -> String {
    guard let spec = schema.object, !spec.isEmpty else { return "any JSON" }
    if let constant = spec["const"] { return "`\(constant.jsonString())`" }
    if let branches = spec["oneOf"]?.array {
      let described = Array(Set(branches.map(describe))).sorted()
      return described.count == 1 ? described[0] : "one of " + described.joined(separator: ", ")
    }
    let names = spec["type"]?.array?.compactMap(\.stringValue) ?? spec["type"]?.stringValue.map { [$0] } ?? []
    let nullable = names.contains("null")
    var described = names.filter { $0 != "null" }.map { name in
      switch name {
      case "array": "array of " + describe(spec["items"] ?? .object([:]))
      default: name
      }
    }.joined(separator: " or ")
    if let allowed = spec["enum"]?.array {
      described = "one of " + allowed.map { "`\($0.jsonString())`" }.joined(separator: ", ")
    }
    return nullable ? described + " or null" : described
  }
}
