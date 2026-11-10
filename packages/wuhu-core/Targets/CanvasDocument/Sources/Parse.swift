import WmdDocument

/// A `.canvas` agent view that is refused whole, naming the line at fault.
public struct CanvasSyntaxError: Error, Hashable, Sendable, CustomStringConvertible {
  /// 1-based line of the agent's text.
  public let line: Int
  public let problem: Problem

  public init(line: Int, problem: Problem) {
    self.line = line
    self.problem = problem
  }

  public enum Problem: Hashable, Sendable {
    case unparseable
    case unknownKind(String)
    case sectionItem
    case nestedSection
    case heading
    case afterConnectors
    case repeatedConnectors
    case strayContinuation
    case attribute(String)
    case repeatedAttribute(String)
    case colorOnText
    case filePath
    case inline(WmdSyntaxError.Problem)
    case connector(String)
    case duplicateID(CanvasID, firstLine: Int)
    case unknownID(CanvasID)
    case missingEndpoint(CanvasID)
    case kindChange(CanvasID)
  }

  public var description: String { "line \(self.line): \(self.problem)" }
}

extension CanvasSyntaxError.Problem: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unparseable: "a line is an item (- kind {…} text), a ## section heading, # Connectors, a connector (a -> b) or a text line indented 2 spaces"
    case let .unknownKind(kind): "unknown kind \(kind); items are sticky, text, rect, ellipse, diamond or file"
    case .sectionItem: "a section is a ## heading, not an item line"
    case .nestedSection: "sections are one level deep: a section cannot sit inside a section"
    case .heading: "the only # heading is # Connectors; sections are ## headings"
    case .afterConnectors: "items and sections come before # Connectors"
    case .repeatedConnectors: "# Connectors appears once"
    case .strayContinuation: "an indented line continues the text of the item above it, and there is none"
    case let .attribute(token): "\(token) is no attribute; {…} holds #id, @x,y, WxH and a colour (yellow pink green blue purple gray white)"
    case let .repeatedAttribute(token): "\(token) repeats an attribute already given"
    case .colorOnText: "free text has no colour"
    case .filePath: "a file card's text is one space path starting with /"
    case let .inline(problem): problem.description
    case let .connector(reason): "a connector is `from -> to {#id elbow right:left 40} \"label\"` (-> end arrow, <-> both, -- none): \(reason)"
    case let .duplicateID(id, first): "#\(id) is already used on line \(first)"
    case let .unknownID(id): "#\(id) is not on this board; omit the id to create a new item or connector"
    case let .missingEndpoint(id): "the connector names \(id), which is not on this board"
    case let .kindChange(id): "#\(id) cannot turn into or out of a section; delete it and write a new one"
    }
  }
}

/// The agent view, read: what it says, before it is matched against a board.
struct Draft {
  struct Item {
    let line: Int
    var id: CanvasID?
    var kind: CanvasKind
    var at: (x: Double, y: Double)?
    var size: CanvasSize?
    var color: CanvasColor?
    var text = Inline()
    /// A sticky's.
    var blocks: [Block]?
    var path: String?
    /// The index in `items` of the section the item is under.
    var section: Int?
  }

  struct Connector {
    let line: Int
    var id: CanvasID?
    var from: CanvasID
    var to: CanvasID
    var arrow: ConnectorArrow
    var style = ConnectorStyle.straight
    var fromSide: CanvasSide?
    var toSide: CanvasSide?
    var offset: Double = 0
    var label = ""
  }

  var items: [Item] = []
  var connectors: [Connector] = []

  init(_ text: String) throws(CanvasSyntaxError) {
    var reader = Reader()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    for (index, line) in lines.enumerated() { try reader.take(line, number: index + 1, into: &self) }
    try reader.close(into: &self)
  }
}

private struct Reader {
  enum Block { case top, section(Int), connectors }
  var block = Block.top
  /// The item whose text later lines continue, and those lines.
  var open: (index: Int, line: Int, lines: [String])?
  var blanks = 0

  mutating func take(_ line: String, number: Int, into draft: inout Draft) throws(CanvasSyntaxError) {
    if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
      if self.open != nil { self.blanks += 1 }
      return
    }
    if line.hasPrefix("  ") {
      guard self.open != nil else { throw CanvasSyntaxError(line: number, problem: .strayContinuation) }
      self.open!.lines += Array(repeating: "", count: self.blanks) + [String(line.dropFirst(2))]
      self.blanks = 0
      return
    }
    try self.close(into: &draft)
    let fail = { (problem: CanvasSyntaxError.Problem) in CanvasSyntaxError(line: number, problem: problem) }
    if line.hasPrefix("#") {
      let level = line.prefix { $0 == "#" }.count
      let rest = line.dropFirst(level)
      guard rest.first == " " else { throw fail(.unparseable) }
      switch level {
      case 1:
        guard rest.dropFirst().trimmingTrailingSpaces == "Connectors" else { throw fail(.heading) }
        if case .connectors = self.block { throw fail(.repeatedConnectors) }
        self.block = .connectors
      case 2:
        if case .connectors = self.block { throw fail(.afterConnectors) }
        let (title, attributes) = try heading(String(rest.dropFirst()), line: number)
        var item = Draft.Item(line: number, kind: .section)
        if let attributes { try item.read(attributes, line: number) }
        draft.items.append(item)
        self.block = .section(draft.items.count - 1)
        self.open = (draft.items.count - 1, number, [title])
      default:
        throw fail(.nestedSection)
      }
      return
    }
    if line.hasPrefix("- ") {
      let section: Int?
      switch self.block {
      case .connectors: throw fail(.afterConnectors)
      case .top: section = nil
      case let .section(index): section = index
      }
      let rest = line.dropFirst(2)
      let word = String(rest.prefix { $0 != " " && $0 != "{" })
      guard let kind = CanvasKind(rawValue: word) else { throw fail(.unknownKind(word)) }
      if kind == .section { throw fail(section == nil ? .sectionItem : .nestedSection) }
      var body = rest.dropFirst(word.count)
      if body.first == " " { body = body.dropFirst() }
      var item = Draft.Item(line: number, kind: kind, section: section)
      if body.first == "{" {
        guard let close = body.firstIndex(of: "}") else { throw fail(.attribute(String(body))) }
        try item.read(String(body[body.index(after: body.startIndex) ..< close]), line: number)
        body = body[body.index(after: close)...]
        if body.first == " " { body = body.dropFirst() }
      }
      if item.color != nil, kind == .text { throw fail(.colorOnText) }
      draft.items.append(item)
      self.open = (draft.items.count - 1, number, [String(body)])
      return
    }
    guard case .connectors = self.block else { throw fail(.unparseable) }
    draft.connectors.append(try connector(line, line: number))
  }

  mutating func close(into draft: inout Draft) throws(CanvasSyntaxError) {
    defer {
      self.open = nil
      self.blanks = 0
    }
    guard let open = self.open else { return }
    switch draft.items[open.index].kind {
    case .file:
      let path = open.lines[0].trimmingTrailingSpaces
      guard open.lines.count == 1, path.hasPrefix("/") else { throw CanvasSyntaxError(line: open.line, problem: .filePath) }
      draft.items[open.index].path = path
    case .sticky:
      draft.items[open.index].blocks = try blocks(open.lines, line: open.line)
    default:
      draft.items[open.index].text = try inline(open.lines, line: open.line)
    }
  }
}

/// A heading's title and the text of its `{…}`, which starts at the first `{` neither escaped nor
/// in code.
private func heading(_ text: String, line: Int) throws(CanvasSyntaxError) -> (title: String, attributes: String?) {
  let characters = Array(text)
  var index = 0
  while index < characters.count {
    switch characters[index] {
    case "\\":
      index += 2
    case "`":
      index = endOfCode(characters, at: index)
    case "{":
      let rest = String(characters[(index + 1)...]).trimmingTrailingSpaces
      guard rest.hasSuffix("}"), !rest.dropLast().contains("}") else {
        throw CanvasSyntaxError(line: line, problem: .attribute("{" + rest))
      }
      return (String(characters[..<index]).trimmingTrailingSpaces, String(rest.dropLast()))
    default:
      index += 1
    }
  }
  return (text.trimmingTrailingSpaces, nil)
}

/// Past the code a run of backticks opens, closed by the next run of the same length; past the
/// run alone when none closes it.
private func endOfCode(_ characters: [Character], at start: Int) -> Int {
  func run(at index: Int) -> Int { characters[index...].prefix { $0 == "`" }.count }
  let fence = run(at: start)
  var index = start + fence
  while index < characters.count {
    guard characters[index] == "`" else {
      index += 1
      continue
    }
    let length = run(at: index)
    if length == fence { return index + length }
    index += length
  }
  return start + fence
}

extension Draft.Item {
  mutating func read(_ attributes: String, line: Int) throws(CanvasSyntaxError) {
    var seen: Set<Character> = []
    for token in attributes.split(separator: " ") {
      let fail = CanvasSyntaxError(line: line, problem: .attribute(String(token)))
      let key: Character
      if token.hasPrefix("#") {
        guard let id = CanvasID(rawValue: String(token.dropFirst())) else { throw fail }
        (key, self.id) = ("#", id)
      } else if token.hasPrefix("@") {
        let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = number(parts[0]), let y = number(parts[1]) else { throw fail }
        (key, self.at) = ("@", (x, y))
      } else if let color = CanvasColor(rawValue: String(token)) {
        (key, self.color) = ("c", color)
      } else {
        let parts = token.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = number(parts[0]), let h = number(parts[1]), w > 0, h > 0 else { throw fail }
        (key, self.size) = ("x", CanvasSize(w: w, h: h))
      }
      guard seen.insert(key).inserted else { throw CanvasSyntaxError(line: line, problem: .repeatedAttribute(String(token))) }
    }
  }
}

private func connector(_ text: String, line: Int) throws(CanvasSyntaxError) -> Draft.Connector {
  func fail(_ reason: String) -> CanvasSyntaxError { CanvasSyntaxError(line: line, problem: .connector(reason)) }
  let words = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
  guard words.count >= 3 else { throw fail("it needs two item ids and an arrow") }
  guard let from = CanvasID(rawValue: String(words[0])) else { throw fail("\(words[0]) is no item id") }
  guard let to = CanvasID(rawValue: String(words[2])) else { throw fail("\(words[2]) is no item id") }
  guard let arrow = ConnectorArrow.allCases.first(where: { glyph($0) == words[1] }) else { throw fail("\(words[1]) is no arrow") }
  var result = Draft.Connector(line: line, from: from, to: to, arrow: arrow)
  var rest = words.count == 4 ? words[3][...] : ""
  if rest.first == "{" {
    guard let close = rest.firstIndex(of: "}") else { throw fail("{ is never closed") }
    try result.read(rest[rest.index(after: rest.startIndex) ..< close], fail: fail)
    rest = rest[rest.index(after: close)...]
  }
  let label = rest.drop { $0 == " " }.trimmingTrailingSpaces
  if !label.isEmpty { result.label = try unquoted(label, fail: fail) }
  return result
}

extension Draft.Connector {
  mutating func read(_ attributes: Substring, fail: (String) -> CanvasSyntaxError) throws(CanvasSyntaxError) {
    var seen: Set<Character> = []
    for token in attributes.split(separator: " ").map(String.init) {
      let key: Character
      if token.hasPrefix("#") {
        guard let id = CanvasID(rawValue: String(token.dropFirst())) else { throw fail("\(token) is no id") }
        (key, self.id) = ("#", id)
      } else if let style = ConnectorStyle(rawValue: token) {
        (key, self.style) = ("s", style)
      } else if let offset = number(token[...]) {
        (key, self.offset) = ("o", offset)
      } else if let colon = token.firstIndex(of: ":") {
        func side(_ name: Substring) throws(CanvasSyntaxError) -> CanvasSide? {
          if name == "auto" { return nil }
          guard let side = CanvasSide(rawValue: String(name)) else { throw fail("\(name) is no side (top right bottom left auto)") }
          return side
        }
        self.fromSide = try side(token[..<colon])
        self.toSide = try side(token[token.index(after: colon)...])
        key = ":"
      } else {
        throw fail("\(token) is no connector attribute")
      }
      guard seen.insert(key).inserted else { throw fail("\(token) repeats an attribute already given") }
    }
  }
}

private func unquoted(_ text: String, fail: (String) -> CanvasSyntaxError) throws(CanvasSyntaxError) -> String {
  guard text.count >= 2, text.first == "\"", text.last == "\"" else { throw fail("a label is one \"quoted\" string") }
  var out = ""
  var escaped = false
  for character in text.dropFirst().dropLast() {
    if escaped {
      switch character {
      case "n": out.append("\n")
      case "t": out.append("\t")
      case "\"", "\\": out.append(character)
      default: throw fail("\\\(character) is no escape; use \\\" \\\\ \\n or \\t")
      }
      escaped = false
    } else if character == "\\" {
      escaped = true
    } else if character == "\"" {
      throw fail("a \" inside a label is written \\\"")
    } else {
      out.append(character)
    }
  }
  guard !escaped else { throw fail("a label ends with a lone \\") }
  return out
}

private func number(_ text: Substring) -> Double? {
  guard let value = Double(text), value.isFinite else { return nil }
  return value
}

extension StringProtocol {
  var trimmingTrailingSpaces: String {
    var text = String(self)
    while text.last == " " || text.last == "\t" { text.removeLast() }
    return text
  }
}
