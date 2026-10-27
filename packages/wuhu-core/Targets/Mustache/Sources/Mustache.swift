import JSONValue
import OrderedCollections

/// A logic-less Mustache template over `JSONValue` data: variables, dotted
/// names, sections, inverted sections, comments and partials, with the spec's
/// standalone-line rule. Nothing is HTML-escaped, so `{{x}}`, `{{{x}}}` and
/// `{{& x}}` are the same tag. `{{=<% %>=}}` sets the delimiters, so a file
/// can show tags literally. Lambdas are not part of it.
public struct Mustache: Sendable {
  public struct SyntaxError: Error, Equatable, Sendable {
    public let message: String
  }

  /// Renders the partial `name` in `scope`; the template indents what it returns.
  public typealias Partial = @Sendable (_ name: String, _ scope: Scope) async -> String

  /// The context stack a name resolves in, innermost last. A frame's
  /// `failures` are names it binds to an error line, hiding outer frames' values.
  public struct Scope: Sendable {
    struct Frame: Sendable {
      var value: JSONValue
      var failures: [String: String] = [:]
    }

    var frames: [Frame]

    public init(_ root: OrderedDictionary<String, JSONValue>, failures: [String: String] = [:]) {
      frames = [Frame(value: .object(root), failures: failures)]
    }

    /// This scope with `names` (and their failures) innermost.
    public func adding(_ names: OrderedDictionary<String, JSONValue>, failures: [String: String]) -> Scope {
      var scope = self
      scope.frames.append(Frame(value: .object(names), failures: failures))
      return scope
    }

    func pushing(_ value: JSONValue) -> Scope {
      var scope = self
      scope.frames.append(Frame(value: value))
      return scope
    }

    func lookup(_ name: String) -> Lookup {
      if name == "." { return .value(frames[frames.count - 1].value) }
      let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      for frame in frames.reversed() {
        if let line = frame.failures[parts[0]] { return .failed(line) }
        guard case let .object(object) = frame.value, var value = object[parts[0]] else { continue }
        for part in parts.dropFirst() {
          guard case let .object(inner) = value, let next = inner[part] else { return .missing }
          value = next
        }
        return .value(value)
      }
      return .missing
    }
  }

  enum Lookup {
    case value(JSONValue)
    case missing
    case failed(String)
  }

  indirect enum Node: Equatable, Sendable {
    case text(String)
    case variable(String)
    case section(String, [Node], inverted: Bool)
    case partial(String, indent: String)
  }

  let nodes: [Node]

  public init(_ source: String) throws(SyntaxError) {
    nodes = try Self.tree(Self.standalone(Self.tokens(source)))
  }

  public func render(_ scope: Scope, partial: Partial) async -> String {
    await Self.render(nodes, scope, partial)
  }

  private static func render(_ nodes: [Node], _ scope: Scope, _ partial: Partial) async -> String {
    var out = ""
    for node in nodes {
      switch node {
      case let .text(text):
        out += text
      case let .variable(name):
        switch scope.lookup(name) {
        case let .value(value): out += value.mustacheText
        case .missing: break
        case let .failed(line): out += line
        }
      case let .section(name, children, inverted):
        switch scope.lookup(name) {
        case let .failed(line):
          out += line + "\n"
        case .missing:
          if inverted { out += await render(children, scope, partial) }
        case let .value(value):
          guard value.isTruthy != inverted else { continue }
          if inverted { out += await render(children, scope, partial) }
          else if case let .array(items) = value {
            for item in items { out += await render(children, scope.pushing(item), partial) }
          } else {
            out += await render(children, scope.pushing(value), partial)
          }
        }
      case let .partial(name, indent):
        out += indented(await partial(name, scope), by: indent)
      }
    }
    return out
  }

  private static func indented(_ text: String, by indent: String) -> String {
    guard !indent.isEmpty, !text.isEmpty else { return text }
    var out = indent
    for (index, character) in zip(text.indices, text) {
      out.append(character)
      if character.isNewline, text.index(after: index) != text.endIndex { out += indent }
    }
    return out
  }

  // MARK: Parsing

  enum Tag: Equatable {
    case variable, section, inverted, close, comment, partial

    var standsAlone: Bool { self != .variable }
  }

  enum Token: Equatable {
    case text(String)
    case tag(Tag, String)
    /// A standalone partial with the whitespace its line began with.
    case indentedPartial(String, indent: String)
  }

  static func tokens(_ source: String) throws(SyntaxError) -> [Token] {
    var tokens: [Token] = []
    var rest = source[...]
    var (opener, closer) = ("{{", "}}")
    while let open = rest.firstRange(of: opener) {
      if open.lowerBound > rest.startIndex { tokens.append(.text(String(rest[..<open.lowerBound]))) }
      let body = rest[open.upperBound...]
      let triple = opener == "{{" && body.first == "{"
      guard let close = body.firstRange(of: triple ? "}" + closer : closer) else {
        throw SyntaxError(message: "a tag opened with \(opener) is never closed")
      }
      var content = trimmed(body[body.index(body.startIndex, offsetBy: triple ? 1 : 0) ..< close.lowerBound])
      rest = body[close.upperBound...]
      if !triple, content.first == "=" {
        let pair = content.count > 1 && content.last == "=" ? content.dropFirst().dropLast().split(whereSeparator: \.isWhitespace) : []
        guard pair.count == 2, !pair.contains(where: { $0.contains("=") }) else {
          throw SyntaxError(message: "a set-delimiter tag names two delimiters without =")
        }
        (opener, closer) = (String(pair[0]), String(pair[1]))
        tokens.append(.tag(.comment, ""))
        continue
      }
      let tag: Tag
      switch triple ? "&" : content.first {
      case "#": tag = .section
      case "^": tag = .inverted
      case "/": tag = .close
      case "!": tag = .comment
      case ">": tag = .partial
      case "&": tag = .variable
      default: tag = .variable
      }
      if !triple, tag != .variable || content.first == "&" { content = trimmed(content.dropFirst()) }
      guard tag == .comment || !content.isEmpty else { throw SyntaxError(message: "a tag names nothing") }
      tokens.append(.tag(tag, String(content)))
    }
    if !rest.isEmpty { tokens.append(.text(String(rest))) }
    return tokens
  }

  // A line holding one non-variable tag and only spaces or tabs besides is
  // dropped whole, keeping the tag; a partial keeps the line's indent.
  static func standalone(_ tokens: [Token]) -> [Token] {
    var lines: [[Token]] = [[]]
    for token in tokens {
      guard case var .text(text) = token else {
        lines[lines.count - 1].append(token)
        continue
      }
      while let newline = text.firstIndex(where: \.isNewline) {
        lines[lines.count - 1].append(.text(String(text[...newline])))
        lines.append([])
        text = String(text[text.index(after: newline)...])
      }
      if !text.isEmpty { lines[lines.count - 1].append(.text(text)) }
    }
    var out: [Token] = []
    for line in lines {
      let tags = line.filter { if case .tag = $0 { true } else { false } }
      let blank = line.allSatisfy { token in
        guard case let .text(text) = token else { return true }
        return text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r\n" }
      }
      guard tags.count == 1, blank, case let .tag(tag, name) = tags[0], tag.standsAlone else {
        out += line
        continue
      }
      if tag == .partial {
        let indent = line.prefix { if case .text = $0 { true } else { false } }
          .map { if case let .text(text) = $0 { text } else { "" } }.joined()
        out.append(.indentedPartial(name, indent: indent))
      } else {
        out.append(tags[0])
      }
    }
    return out
  }

  static func tree(_ tokens: [Token]) throws(SyntaxError) -> [Node] {
    var stack: [(name: String, inverted: Bool, nodes: [Node])] = [("", false, [])]
    for token in tokens {
      switch token {
      case let .text(text):
        stack[stack.count - 1].nodes.append(.text(text))
      case let .indentedPartial(name, indent):
        stack[stack.count - 1].nodes.append(.partial(name, indent: indent))
      case let .tag(tag, name):
        switch tag {
        case .variable: stack[stack.count - 1].nodes.append(.variable(name))
        case .partial: stack[stack.count - 1].nodes.append(.partial(name, indent: ""))
        case .comment: break
        case .section, .inverted: stack.append((name, tag == .inverted, []))
        case .close:
          guard stack.count > 1 else { throw SyntaxError(message: "{{/\(name)}} closes no section") }
          let section = stack.removeLast()
          guard section.name == name else {
            throw SyntaxError(message: "{{/\(name)}} closes {{\(section.inverted ? "^" : "#")\(section.name)}}")
          }
          stack[stack.count - 1].nodes.append(.section(name, section.nodes, inverted: section.inverted))
        }
      }
    }
    guard stack.count == 1 else {
      let open = stack[stack.count - 1]
      throw SyntaxError(message: "{{\(open.inverted ? "^" : "#")\(open.name)}} is never closed")
    }
    return stack[0].nodes
  }

  private static func trimmed(_ text: Substring) -> Substring {
    var text = text
    while text.first?.isWhitespace == true { text = text.dropFirst() }
    while text.last?.isWhitespace == true { text = text.dropLast() }
    return text
  }
}

extension JSONValue {
  var isTruthy: Bool {
    switch self {
    case .null, .bool(false): false
    case let .array(items): !items.isEmpty
    default: true
    }
  }

  var mustacheText: String {
    switch self {
    case .null: ""
    case let .bool(value): value ? "true" : "false"
    case let .integer(value): String(value)
    case let .number(value): value.description
    case let .string(value): value
    case let .array(items): items.map(\.mustacheText).joined(separator: ", ")
    case .object: ""
    }
  }
}
