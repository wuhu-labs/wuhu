import Foundation
import JSONValue
import OrderedCollections
import Yams

public enum FrontmatterError: Error, Equatable, Sendable {
  /// The frontmatter is not YAML, or not a mapping of keys.
  case malformed(String)
  /// YAML this editor will not rewrite: it refuses rather than normalize.
  case unsupported(String)
  /// The patch itself is wrong.
  case invalid(String)
}

/// A document's YAML frontmatter as attributes: read from the source, and
/// patched key by key without touching the bytes of anything else.
public enum Frontmatter {
  /// The top-level keys in source order; an empty mapping when the document has
  /// no frontmatter.
  public static func attributes(of data: Data) throws -> OrderedDictionary<String, JSONValue> {
    let document = try Document(data)
    guard let yaml = document.yaml else { return [:] }
    guard let root = try compose(document.text(of: yaml)) else { return [:] }
    return try attributes(of: root)
  }

  /// `data` with `set` written and `remove` dropped. A changed key is edited in
  /// place, a new key is appended, and every other byte is kept: the body, the
  /// newline style, and the order, comments and quoting of untouched keys.
  public static func patch(_ data: Data, set: OrderedDictionary<String, JSONValue>, remove: [String]) throws -> Data {
    let overlap = remove.filter { set[$0] != nil }
    guard overlap.isEmpty else {
      throw FrontmatterError.invalid("keys both set and removed: \(overlap.joined(separator: ", "))")
    }
    guard !set.keys.contains(""), !remove.contains("") else { throw FrontmatterError.invalid("a key must not be empty") }
    let document = try Document(data)
    var expected = try attributes(of: data)
    for (key, value) in set { expected[key] = value }
    for key in remove { expected[key] = nil }

    let newline = document.newline
    let rendered = { (key: String, value: JSONValue) throws -> [UInt8] in
      Array(try entry(key, value, indent: "").map { $0 + newline }.joined().utf8)
    }
    var out: [UInt8]
    if let yaml = document.yaml {
      let entries = try Self.entries(document, yaml)
      var lines = Array(document.lines[yaml])
      var edits: [(range: Range<Int>, replacement: [[UInt8]])] = []
      var appended: [UInt8] = []
      for (key, value) in set {
        if let found = entries[key] {
          edits.append((found, [try rendered(key, value)]))
        } else {
          appended += try rendered(key, value)
        }
      }
      for key in remove {
        if let found = entries[key] { edits.append((found, [])) }
      }
      for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        lines.replaceSubrange(edit.range.lowerBound - yaml.lowerBound ..< edit.range.upperBound - yaml.lowerBound, with: edit.replacement)
      }
      out = document.bom + document.lines[..<yaml.lowerBound].joined() + lines.joined() + appended
        + document.lines[yaml.upperBound...].joined()
    } else {
      guard !set.isEmpty else { return data }
      let head = Array(("---" + newline).utf8)
      out = document.bom + head + (try set.flatMap { try rendered($0.key, $0.value) }) + head + document.lines.joined()
    }
    let result = Data(out)
    let written = try attributes(of: result)
    guard Dictionary(uniqueKeysWithValues: written.map { ($0.key, $0.value) })
      == Dictionary(uniqueKeysWithValues: expected.map { ($0.key, $0.value) })
    else {
      throw FrontmatterError.unsupported("the patched frontmatter would not read back as written")
    }
    return result
  }

  // MARK: - Reading

  private static func compose(_ yaml: String) throws -> Node? {
    try parsed { try Yams.compose(yaml: yaml) }
  }

  private static func parsed<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as YamlError {
      if case .duplicatedKeysInMapping = error {
        throw FrontmatterError.unsupported("duplicate keys")
      }
      throw FrontmatterError.malformed("\(error)")
    } catch {
      throw FrontmatterError.malformed("\(error)")
    }
  }

  private static func attributes(of root: Node) throws -> OrderedDictionary<String, JSONValue> {
    guard let mapping = root.mapping else { throw FrontmatterError.malformed("the frontmatter is not a mapping of keys") }
    var out: OrderedDictionary<String, JSONValue> = [:]
    for (key, value) in mapping {
      guard let name = key.scalar?.string else { throw FrontmatterError.unsupported("a key that is not a scalar") }
      out[name] = try json(value, depth: 0)
    }
    return out
  }

  private static func json(_ node: Node, depth: Int) throws -> JSONValue {
    guard depth < 64 else { throw FrontmatterError.unsupported("nesting deeper than 64 levels") }
    switch node {
    case let .scalar(scalar):
      return scalarJSON(scalar)
    case let .sequence(sequence):
      return .array(try sequence.map { try json($0, depth: depth + 1) })
    case let .mapping(mapping):
      var out: OrderedDictionary<String, JSONValue> = [:]
      for (key, value) in mapping {
        guard let name = key.scalar?.string else { throw FrontmatterError.unsupported("a key that is not a scalar") }
        out[name] = try json(value, depth: depth + 1)
      }
      return .object(out)
    case .alias:
      throw FrontmatterError.unsupported("aliases")
    }
  }

  // Timestamps and non-finite floats keep the author's text, so every value
  // stays JSON.
  private static func scalarJSON(_ scalar: Node.Scalar) -> JSONValue {
    let explicit = scalar.tag.rawValue
    let name: Tag.Name = if !explicit.isEmpty {
      Tag.Name(rawValue: explicit)
    } else if scalar.style == .plain || scalar.style == .any {
      Resolver.default.resolveTag(of: .scalar(Node.Scalar(scalar.string)))
    } else {
      .str
    }
    switch name {
    case .null: return .null
    case .bool: return Bool.construct(from: scalar).map(JSONValue.bool) ?? .string(scalar.string)
    case .int: return Int.construct(from: scalar).map(JSONValue.integer) ?? .string(scalar.string)
    case .float:
      guard let value = Double.construct(from: scalar), value.isFinite else { return .string(scalar.string) }
      return .number(value)
    default: return .string(scalar.string)
    }
  }

  // MARK: - Editing

  // The line range of each top-level key: from its key's line to the next
  // key's, less trailing blank lines and unindented comments, which stay put.
  private static func entries(_ document: Document, _ yaml: Range<Int>) throws -> [String: Range<Int>] {
    let text = document.text(of: yaml)
    if let first = text.split(separator: "\n").first(where: { line in
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    })?.drop(while: { $0 == " " || $0 == "\t" }), first.hasPrefix("{") {
      throw FrontmatterError.unsupported("a flow-style frontmatter mapping")
    }
    // The parser keeps its anchors alive, and the basic resolver leaves an
    // implicit tag distinguishable from an explicit one.
    let parser = try parsed { try Yams.Parser(yaml: text, resolver: .basic) }
    guard let root = try parsed({ try parser.singleRoot() }) else { return [:] }
    guard let mapping = root.mapping else { throw FrontmatterError.malformed("the frontmatter is not a mapping of keys") }
    try withExtendedLifetime(parser) { try refuseUnsupported(root, key: false, depth: 0) }
    var keys: [(name: String, line: Int, column: Int)] = []
    for (key, _) in mapping {
      guard let scalar = key.scalar, let mark = scalar.mark else {
        throw FrontmatterError.unsupported("a key that is not a scalar")
      }
      let line = yaml.lowerBound + mark.line - 1
      let before = document.lines[line].prefix(mark.column - 1)
      guard before.allSatisfy({ $0 == UInt8(ascii: " ") }) else {
        throw FrontmatterError.unsupported("the key \(scalar.string) does not start its line")
      }
      keys.append((scalar.string, line, mark.column - 1))
    }
    var ranges: [String: Range<Int>] = [:]
    for (index, key) in keys.enumerated() {
      var end = index + 1 < keys.count ? keys[index + 1].line : yaml.upperBound
      while end - 1 > key.line, detached(document.lines[end - 1], indent: key.column) {
        end -= 1
      }
      ranges[key.name] = key.line ..< end
    }
    return ranges
  }

  private static func detached(_ line: [UInt8], indent: Int) -> Bool {
    let content = line.drop { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
    let text = content.prefix { $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\n") }
    if text.isEmpty { return true }
    return text.first == UInt8(ascii: "#") && line.count - content.count <= indent
  }

  // A quoted or block scalar carries `str` and a hashed key its resolved tag, which
  // under the basic resolver is `str` too; anything else was written.
  private static func refuseUnsupported(_ node: Node, key: Bool, depth: Int) throws {
    guard depth < 64 else { throw FrontmatterError.unsupported("nesting deeper than 64 levels") }
    if node.anchor != nil { throw FrontmatterError.unsupported("anchors and aliases") }
    switch node {
    case let .scalar(scalar):
      let tag = scalar.tag.rawValue
      let plain = scalar.style == .plain || scalar.style == .any
      if !tag.isEmpty, tag != Tag.Name.str.rawValue || (plain && !key) {
        throw FrontmatterError.unsupported("tags")
      }
    case let .sequence(sequence):
      if !sequence.tag.rawValue.isEmpty { throw FrontmatterError.unsupported("tags") }
      for item in sequence { try refuseUnsupported(item, key: false, depth: depth + 1) }
    case let .mapping(mapping):
      if !mapping.tag.rawValue.isEmpty { throw FrontmatterError.unsupported("tags") }
      for (name, value) in mapping {
        if let scalar = name.scalar, scalar.string == "<<", scalar.style == .plain || scalar.style == .any {
          throw FrontmatterError.unsupported("merge keys")
        }
        try refuseUnsupported(name, key: true, depth: depth + 1)
        try refuseUnsupported(value, key: false, depth: depth + 1)
      }
    case .alias:
      throw FrontmatterError.unsupported("anchors and aliases")
    }
  }

  private static func entry(_ key: String, _ value: JSONValue, indent: String) throws -> [String] {
    let head = indent + string(key) + ":"
    if let text = try scalar(value) { return [head + " " + text] }
    return [head] + (try block(value, indent: indent + "  "))
  }

  private static func block(_ value: JSONValue, indent: String) throws -> [String] {
    switch value {
    case let .object(fields):
      return try fields.flatMap { try entry($0.key, $0.value, indent: indent) }
    case let .array(items):
      return try items.flatMap { item -> [String] in
        if let text = try scalar(item) { return [indent + "- " + text] }
        var lines = try block(item, indent: indent + "  ")
        lines[0] = indent + "- " + lines[0].dropFirst(indent.count + 2)
        return lines
      }
    default:
      return [indent + (try scalar(value) ?? "null")]
    }
  }

  private static func scalar(_ value: JSONValue) throws -> String? {
    switch value {
    case .null: return "null"
    case let .bool(flag): return flag ? "true" : "false"
    case let .integer(number): return String(number)
    case let .number(number):
      guard number.isFinite else { throw FrontmatterError.invalid("\(number) is not a JSON number") }
      return String(number)
    case let .string(text): return string(text)
    case let .array(items): return items.isEmpty ? "[]" : nil
    case let .object(fields): return fields.isEmpty ? "{}" : nil
    }
  }

  // Plain when YAML reads it back as this very string, else a double-quoted
  // JSON string, which is valid YAML.
  private static func string(_ text: String) -> String {
    plain(text) ? text : JSONValue.string(text).jsonString()
  }

  private static func plain(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return false }
    if first == " " || last == " " || last == ":" { return false }
    if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return false }
    if text.contains(": ") || text.contains(" #") { return false }
    if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x85 || $0.value == 0xFEFF || $0.value == 0x2028 || $0.value == 0x2029 }) {
      return false
    }
    return Resolver.default.resolveTag(of: .scalar(Node.Scalar(text))) == .str
  }
}

// A document as lines of bytes, each with its own line ending, so an edit
// rewrites whole lines and keeps every other byte.
private struct Document {
  let bom: [UInt8]
  let lines: [[UInt8]]
  /// The frontmatter's lines, between its `---` and its closing `---` or `...`.
  let yaml: Range<Int>?
  let newline: String

  init(_ data: Data) throws {
    var bytes = [UInt8](data)
    guard String(validating: bytes, as: UTF8.self) != nil else { throw FrontmatterError.invalid("the document is not UTF-8 text") }
    let marker: [UInt8] = [0xEF, 0xBB, 0xBF]
    bom = bytes.starts(with: marker) ? marker : []
    bytes.removeFirst(bom.count)
    for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\r") {
      guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") else {
        throw FrontmatterError.unsupported("carriage-return line endings")
      }
    }
    var lines: [[UInt8]] = []
    var start = 0
    for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
      lines.append(Array(bytes[start ... index]))
      start = index + 1
    }
    if start < bytes.count { lines.append(Array(bytes[start...])) }
    self.lines = lines
    let content = lines.map { line in
      String(decoding: line.prefix { $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    }
    newline = lines.first.map { $0.suffix(2) == [UInt8(ascii: "\r"), UInt8(ascii: "\n")] } == true ? "\r\n" : "\n"
    guard content.first == "---" else {
      yaml = nil
      return
    }
    guard let close = content.indices.dropFirst().first(where: { content[$0] == "---" || content[$0] == "..." }) else {
      throw FrontmatterError.malformed("the frontmatter opened on the first line is never closed")
    }
    yaml = 1 ..< close
  }

  func text(of range: Range<Int>) -> String {
    lines[range].map { line in
      String(decoding: line.prefix { $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    }.map { $0 + "\n" }.joined()
  }
}
