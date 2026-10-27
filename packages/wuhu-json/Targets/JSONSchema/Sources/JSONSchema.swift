import JSONValue

/// A JSON Schema subset: `type`, `enum`, `const`, `properties`, `required`,
/// `additionalProperties`, `items`, `min`/`maxItems`, `min`/`maxLength`,
/// `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `allOf`,
/// `anyOf`, `oneOf` and `not`. Annotations are ignored; any other keyword is
/// refused when the schema is read, so a schema never means less than it says.
public struct JSONSchema: Sendable, Hashable {
  let node: Node

  public init(_ value: JSONValue) throws(JSONSchemaError) {
    node = try Node(value, at: "#")
  }

  /// Every violation, each naming the instance path it is about (`$.a[0]`).
  public func violations(of instance: JSONValue) -> [String] {
    var found: [String] = []
    node.check(instance, at: "$", into: &found)
    return found
  }
}

public struct JSONSchemaError: Error, Hashable, Sendable, CustomStringConvertible {
  public let description: String
}

enum Kind: String, CaseIterable, Sendable {
  case null, boolean, integer, number, string, array, object

  func matches(_ value: JSONValue) -> Bool {
    switch (self, value) {
    case (.null, .null), (.boolean, .bool), (.string, .string), (.array, .array), (.object, .object): true
    case (.integer, .integer), (.number, .integer), (.number, .number): true
    case let (.integer, .number(number)): number.isFinite && number.rounded() == number
    default: false
    }
  }
}

indirect enum Node: Sendable, Hashable {
  case always(Bool)
  case rules([Rule])

  enum Rule: Sendable, Hashable {
    case type(Set<Kind>)
    case oneOfValues([JSONValue])
    case const(JSONValue)
    case properties([String: Node])
    case required([String])
    case additionalProperties(known: Set<String>, Node)
    case items(Node)
    case count(Bound<Int>, of: Countable)
    case number(Bound<Double>)
    case allOf([Node])
    case anyOf([Node])
    case oneOf([Node])
    case not(Node)
  }

  enum Countable: Sendable, Hashable { case items, characters }

  enum Bound<Value: Comparable & Sendable & Hashable>: Sendable, Hashable {
    case atLeast(Value), atMost(Value), above(Value), below(Value)

    func admits(_ value: Value) -> Bool {
      switch self {
      case let .atLeast(bound): value >= bound
      case let .atMost(bound): value <= bound
      case let .above(bound): value > bound
      case let .below(bound): value < bound
      }
    }

    var phrase: String {
      switch self {
      case let .atLeast(bound): "at least \(bound)"
      case let .atMost(bound): "at most \(bound)"
      case let .above(bound): "more than \(bound)"
      case let .below(bound): "less than \(bound)"
      }
    }
  }

  static let annotations: Set<String> = ["$schema", "$id", "$comment", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly"]

  init(_ value: JSONValue, at path: String) throws(JSONSchemaError) {
    if case let .bool(flag) = value {
      self = .always(flag)
      return
    }
    guard case let .object(schema) = value else { throw JSONSchemaError(description: "\(path) is not a schema: a schema is an object or a boolean") }
    func fail(_ text: String) -> JSONSchemaError { JSONSchemaError(description: "\(path): \(text)") }
    func subschema(_ key: String) throws(JSONSchemaError) -> Node { try Node(schema[key]!, at: "\(path)/\(key)") }
    func list(_ key: String) throws(JSONSchemaError) -> [Node] {
      guard case let .array(items) = schema[key]!, !items.isEmpty else { throw fail("\(key) is a nonempty array of schemas") }
      var nodes: [Node] = []
      for (index, item) in items.enumerated() { nodes.append(try Node(item, at: "\(path)/\(key)/\(index)")) }
      return nodes
    }
    func count(_ key: String) throws(JSONSchemaError) -> Int {
      guard let count = schema[key]!.intValue, count >= 0 else { throw fail("\(key) is a nonnegative integer") }
      return count
    }
    func number(_ key: String) throws(JSONSchemaError) -> Double {
      guard let number = schema[key]!.doubleValue else { throw fail("\(key) is a number") }
      return number
    }
    var rules: [Rule] = []
    for key in schema.keys where !Self.annotations.contains(key) {
      switch key {
      case "type":
        let names: [JSONValue] = schema[key]!.array ?? [schema[key]!]
        var kinds: Set<Kind> = []
        for name in names {
          guard let kind = name.stringValue.flatMap(Kind.init(rawValue:)) else {
            throw fail("type is one of \(Kind.allCases.map(\.rawValue).joined(separator: ", ")) or an array of them")
          }
          kinds.insert(kind)
        }
        rules.append(.type(kinds))
      case "enum":
        guard let values = schema[key]!.array, !values.isEmpty else { throw fail("enum is a nonempty array") }
        rules.append(.oneOfValues(values))
      case "const":
        rules.append(.const(schema[key]!))
      case "properties":
        guard let properties = schema[key]!.object else { throw fail("properties is an object of schemas") }
        var nodes: [String: Node] = [:]
        for (name, property) in properties { nodes[name] = try Node(property, at: "\(path)/properties/\(name)") }
        rules.append(.properties(nodes))
      case "required":
        guard let names = schema[key]!.array?.compactMap(\.stringValue), names.count == schema[key]!.array?.count else {
          throw fail("required is an array of property names")
        }
        rules.append(.required(names))
      case "additionalProperties":
        rules.append(.additionalProperties(known: Set(schema["properties"]?.object?.keys.elements ?? []), try subschema(key)))
      case "items":
        rules.append(.items(try subschema(key)))
      case "minItems": rules.append(.count(.atLeast(try count(key)), of: .items))
      case "maxItems": rules.append(.count(.atMost(try count(key)), of: .items))
      case "minLength": rules.append(.count(.atLeast(try count(key)), of: .characters))
      case "maxLength": rules.append(.count(.atMost(try count(key)), of: .characters))
      case "minimum": rules.append(.number(.atLeast(try number(key))))
      case "maximum": rules.append(.number(.atMost(try number(key))))
      case "exclusiveMinimum": rules.append(.number(.above(try number(key))))
      case "exclusiveMaximum": rules.append(.number(.below(try number(key))))
      case "allOf": rules.append(.allOf(try list(key)))
      case "anyOf": rules.append(.anyOf(try list(key)))
      case "oneOf": rules.append(.oneOf(try list(key)))
      case "not": rules.append(.not(try subschema(key)))
      default:
        throw fail("\(key) is not a supported keyword")
      }
    }
    self = .rules(rules)
  }

  func admits(_ value: JSONValue) -> Bool {
    var found: [String] = []
    check(value, at: "$", into: &found)
    return found.isEmpty
  }

  func check(_ value: JSONValue, at path: String, into found: inout [String]) {
    guard case let .rules(rules) = self else {
      if self == .always(false) { found.append("\(path) is not allowed") }
      return
    }
    for rule in rules {
      switch rule {
      case let .type(kinds):
        if !kinds.contains(where: { $0.matches(value) }) {
          found.append("\(path) is \(Self.kindName(of: value)), not \(kinds.map(\.rawValue).sorted().joined(separator: " or "))")
        }
      case let .oneOfValues(values):
        if !values.contains(value) { found.append("\(path) is not one of \(JSONValue.array(values).jsonString())") }
      case let .const(expected):
        if value != expected { found.append("\(path) is not \(expected.jsonString())") }
      case let .properties(nodes):
        guard let object = value.object else { continue }
        for (name, node) in nodes.sorted(by: { $0.key < $1.key }) {
          if let property = object[name] { node.check(property, at: "\(path).\(name)", into: &found) }
        }
      case let .required(names):
        guard let object = value.object else { continue }
        for name in names where object[name] == nil { found.append("\(path).\(name) is required") }
      case let .additionalProperties(known, node):
        guard let object = value.object else { continue }
        for (name, property) in object where !known.contains(name) {
          if node == .always(false) {
            found.append("\(path).\(name) is not an allowed property")
          } else {
            node.check(property, at: "\(path).\(name)", into: &found)
          }
        }
      case let .items(node):
        guard let items = value.array else { continue }
        for (index, item) in items.enumerated() { node.check(item, at: "\(path)[\(index)]", into: &found) }
      case let .count(bound, countable):
        let count: Int? = switch countable {
        case .items: value.array?.count
        case .characters: value.stringValue?.unicodeScalars.count
        }
        if let count, !bound.admits(count) {
          found.append("\(path) has \(count) \(countable == .items ? "items" : "characters"), wants \(bound.phrase)")
        }
      case let .number(bound):
        if let number = value.doubleValue, !bound.admits(number) { found.append("\(path) is \(number), wants \(bound.phrase)") }
      case let .allOf(nodes):
        for node in nodes { node.check(value, at: path, into: &found) }
      case let .anyOf(nodes):
        if !nodes.contains(where: { $0.admits(value) }) { found.append("\(path) matches none of anyOf") }
      case let .oneOf(nodes):
        let matching = nodes.count(where: { $0.admits(value) })
        if matching != 1 { found.append("\(path) matches \(matching) of oneOf, wants exactly 1") }
      case let .not(node):
        if node.admits(value) { found.append("\(path) matches a schema under not") }
      }
    }
  }

  static func kindName(of value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "boolean"
    case .integer: "integer"
    case .number: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }
}
