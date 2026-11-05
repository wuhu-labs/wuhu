import JSONValue

extension Content {
  init(markdown: String) throws(WmdSyntaxError) {
    var parser = Parser(markdown)
    self = try parser.parse()
  }
}

private struct Parser {
  private let lines: [Substring]
  private var index = 0

  init(_ markdown: String) {
    var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    self.lines = lines.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
  }

  mutating func parse() throws(WmdSyntaxError) -> Content {
    var content = Content()
    if self.lines.first == "---" { content.frontmatter = try self.frontmatter() }
    while self.index < self.lines.count {
      if isBlank(self.lines[self.index]) {
        self.index += 1
        continue
      }
      content.blocks.append(try self.block())
    }
    return content
  }

  private func failure(_ problem: WmdSyntaxError.Problem, line: Int? = nil) -> WmdSyntaxError {
    WmdSyntaxError(line: line ?? self.index + 1, problem: problem)
  }

  private mutating func block() throws(WmdSyntaxError) -> Block {
    let line = self.lines[self.index]
    let number = self.index + 1
    let indent = leadingSpaces(line)
    let body = line.dropFirst(indent)
    if let problem = refusal(body) { throw self.failure(problem) }
    if let item = listItem(body) {
      guard indent % 4 == 0 else { throw self.failure(.listIndent(spaces: indent)) }
      var text = String(item.text)
      self.index += 1
      let continuation = indent + 4
      while true {
        var next = self.index
        while next < self.lines.count, isBlank(self.lines[next]) { next += 1 }
        guard next < self.lines.count, leadingSpaces(self.lines[next]) == continuation else { break }
        let nextBody = self.lines[next].dropFirst(continuation)
        guard refusal(nextBody) == nil, listItem(nextBody) == nil else { break }
        text += String(repeating: "\n", count: next - self.index + 1)
        text += nextBody
        self.index = next + 1
      }
      return .list(level: indent / 4, style: item.style, text: try Inline(markdown: text, line: number))
    }
    if indent >= 4 { throw self.failure(.indentedCode) }
    if let level = headingLevel(body) {
      var text = String(body.dropFirst(level).drop { $0 == " " })
      self.index += 1
      while endsInOddBackslashes(text), self.index < self.lines.count {
        text += "\n"
        text += self.lines[self.index]
        self.index += 1
      }
      return .heading(level: level, text: try Inline(markdown: text, line: number))
    }
    if let fence = fenceLength(body) { return try self.code(fence: fence, info: body.dropFirst(fence)) }
    var text = String(body)
    self.index += 1
    while self.index < self.lines.count {
      let next = self.lines[self.index]
      guard !isBlank(next), !startsBlock(next) else { break }
      text += "\n"
      text += next.drop { $0 == " " }
      self.index += 1
    }
    return .paragraph(try Inline(markdown: text, line: number))
  }

  private mutating func code(fence: Int, info: Substring) throws(WmdSyntaxError) -> Block {
    let opening = self.index + 1
    let info = info.trimmingSpaces
    guard info.isEmpty || info == "wuhu-view" else { throw self.failure(.codeInfo(String(info))) }
    var body: [Substring] = []
    self.index += 1
    while self.index < self.lines.count {
      let line = self.lines[self.index]
      self.index += 1
      if line.count >= fence, line.allSatisfy({ $0 == "`" }) {
        let text = body.joined(separator: "\n")
        return info.isEmpty ? .code(text) : try self.view(text, line: opening)
      }
      body.append(line)
    }
    throw self.failure(.unclosedFence, line: opening)
  }

  private func view(_ text: String, line: Int) throws(WmdSyntaxError) -> Block {
    guard case let .object(object)? = JSONValue.parse(text) else { throw self.failure(.view("not a JSON object"), line: line) }
    guard Set(object.keys) == ["view", "config", "sql"] else {
      throw self.failure(.view("keys must be exactly view, config and sql"), line: line)
    }
    guard case let .string(view)? = object["view"], case let .string(sql)? = object["sql"] else {
      throw self.failure(.view("view and sql must be strings"), line: line)
    }
    return .view(view: view, config: object["config"]!, sql: sql)
  }

  private mutating func frontmatter() throws(WmdSyntaxError) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    self.index = 1
    while self.index < self.lines.count {
      let line = self.lines[self.index]
      let number = self.index + 1
      self.index += 1
      if line == "---" { return result }
      if isBlank(line) { continue }
      guard let colon = line.firstIndex(of: ":"), isKey(line[..<colon]) else {
        throw self.failure(.frontmatter("expected key: value"), line: number)
      }
      let key = String(line[..<colon])
      guard result[key] == nil else { throw self.failure(.frontmatter("\(key) appears twice"), line: number) }
      let rest = line[line.index(after: colon)...]
      if rest.isEmpty {
        var items: [JSONValue] = []
        while self.index < self.lines.count, self.lines[self.index].hasPrefix("  -") {
          let item = self.lines[self.index].dropFirst(3)
          guard item.isEmpty || item.first == " ", let value = yamlScalar(String(item.trimmingSpaces)) else {
            throw self.failure(.frontmatter("list items are \"  - value\" with a plain or quoted scalar"))
          }
          items.append(value)
          self.index += 1
        }
        result[key] = items.isEmpty ? .null : .array(items)
        continue
      }
      guard rest.first == " ", let value = yamlScalar(String(rest.trimmingSpaces)) else {
        throw self.failure(.frontmatter("quote the value of \(key) as a JSON string"), line: number)
      }
      result[key] = value
    }
    throw self.failure(.unclosedFrontmatter, line: 1)
  }
}

private func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

private func leadingSpaces(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }

private func isKey(_ key: Substring) -> Bool {
  guard let first = key.first, first != "-" else { return false }
  return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }
}

private func endsInOddBackslashes(_ text: String) -> Bool {
  text.reversed().prefix { $0 == "\\" }.count % 2 == 1
}

private func headingLevel(_ body: Substring) -> Int? {
  let level = body.prefix { $0 == "#" }.count
  guard level > 0, body.count == level || body.dropFirst(level).first == " " else { return nil }
  return level
}

private func fenceLength(_ body: Substring) -> Int? {
  let count = body.prefix { $0 == "`" }.count
  return count >= 3 && !body.dropFirst(count).contains("`") ? count : nil
}

private func listItem(_ body: Substring) -> (style: WmdSchema.ListStyle, text: Substring)? {
  for (marker, style) in [("- [ ]", WmdSchema.ListStyle.todo), ("- [x]", .done), ("- [X]", .done), ("-", .unordered)] {
    guard body.hasPrefix(marker) else { continue }
    let rest = body.dropFirst(marker.count)
    if rest.isEmpty { return (style, rest) }
    if rest.first == " " { return (style, rest.dropFirst()) }
  }
  let digits = body.prefix { $0.isASCII && $0.isNumber }
  guard (1 ... 9).contains(digits.count) else { return nil }
  let rest = body.dropFirst(digits.count)
  guard rest.first == "." else { return nil }
  let text = rest.dropFirst()
  if text.isEmpty { return (.ordered, text) }
  return text.first == " " ? (.ordered, text.dropFirst()) : nil
}

/// Constructs outside the subset, recognised where they would start a block.
private func refusal(_ body: Substring) -> WmdSyntaxError.Problem? {
  guard let first = body.first else { return nil }
  let visible = body.filter { $0 != " " }
  if visible.count >= 3, let mark = visible.first, "-*_".contains(mark), visible.allSatisfy({ $0 == mark }) { return .thematicBreak }
  if visible.count >= 1, visible.allSatisfy({ $0 == "=" }) { return .setextHeading }
  switch first {
  case ">": return .quote
  case "|": return .table
  case "<" where body.dropFirst().first.map(opensTag) == true: return .html
  case "*", "+":
    if body.count == 1 || body.dropFirst().first == " " { return .listMarker(String(first)) }
  case "~" where body.hasPrefix("~~~"): return .tildeFence
  default: break
  }
  if let level = headingLevel(body), level > 3 { return .deepHeading(level: level) }
  let digits = body.prefix { $0.isASCII && $0.isNumber }
  if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(")"),
     body.count == digits.count + 1 || body.dropFirst(digits.count + 1).first == " "
  {
    return .listMarker(String(digits) + ")")
  }
  return nil
}

private func startsBlock(_ line: Substring) -> Bool {
  let body = line.drop { $0 == " " }
  return refusal(body) != nil || listItem(body) != nil || headingLevel(body) != nil || fenceLength(body) != nil
}

extension Substring {
  fileprivate var trimmingSpaces: Substring {
    var trimmed = self.drop { $0 == " " }
    while trimmed.last == " " { trimmed = trimmed.dropLast() }
    return trimmed
  }
}

func yamlScalar(_ text: String) -> JSONValue? {
  switch text {
  case "", "null", "~": return .null
  case "true": return .bool(true)
  case "false": return .bool(false)
  default: break
  }
  if let integer = Int(text), String(integer) == text { return .integer(integer) }
  if isDecimal(text), let number = Double(text) { return .number(number) }
  guard let first = text.first else { return nil }
  switch first {
  case "\"":
    guard case let .string(string)? = JSONValue.parse(text) else { return nil }
    return .string(string)
  case "'":
    guard text.count >= 2, text.last == "'" else { return nil }
    let inner = text.dropFirst().dropLast()
    guard String(inner).replacing("''", with: "").firstIndex(of: "'") == nil else { return nil }
    return .string(String(inner).replacing("''", with: "'"))
  case "[", "{":
    return JSONValue.parse(text)
  default:
    if "&*!|>%@`#,?".contains(first) || text.hasPrefix("- ") || text == "-" { return nil }
    if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") { return nil }
    return .string(text)
  }
}

private func isDecimal(_ text: String) -> Bool {
  var characters = Substring(text)
  if characters.first == "-" { characters = characters.dropFirst() }
  let whole = characters.prefix { $0.isASCII && $0.isNumber }
  guard !whole.isEmpty else { return false }
  characters = characters.dropFirst(whole.count)
  var marked = false
  if characters.first == "." {
    let fraction = characters.dropFirst().prefix { $0.isASCII && $0.isNumber }
    guard !fraction.isEmpty else { return false }
    characters = characters.dropFirst(1 + fraction.count)
    marked = true
  }
  if characters.first == "e" || characters.first == "E" {
    characters = characters.dropFirst()
    if characters.first == "+" || characters.first == "-" { characters = characters.dropFirst() }
    let exponent = characters.prefix { $0.isASCII && $0.isNumber }
    guard !exponent.isEmpty else { return false }
    characters = characters.dropFirst(exponent.count)
    marked = true
  }
  return marked && characters.isEmpty
}
