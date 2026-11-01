import JSONValue

extension Content {
  /// The canonical markdown: deterministic, so an agent's `edit` matches what `read` returned.
  var markdown: String {
    var out = ""
    if !self.frontmatter.isEmpty {
      out += "---\n"
      for key in self.frontmatter.keys.sorted() {
        out += frontmatterLines(key: key, value: self.frontmatter[key]!)
      }
      out += "---\n"
    }
    var numbering = Numbering()
    var previousWasList = false
    for block in self.blocks {
      guard let rendered = block.markdown(numbering: &numbering) else { continue }
      let isList = if case .list = block { true } else { false }
      if !out.isEmpty { out += isList && previousWasList ? "" : "\n" }
      out += rendered + "\n"
      previousWasList = isList
    }
    return out
  }
}

struct Numbering {
  private var counters: [Int] = []

  mutating func next(level: Int, style: ListStyle?) -> Int {
    guard let style else {
      self.counters = []
      return 0
    }
    if self.counters.count > level + 1 { self.counters.removeLast(self.counters.count - level - 1) }
    while self.counters.count < level + 1 { self.counters.append(0) }
    guard style == .ordered else {
      self.counters[level] = 0
      return 0
    }
    self.counters[level] += 1
    return self.counters[level]
  }
}

extension Block {
  /// nil for a block that renders to nothing (an empty paragraph), which the agent view drops.
  func markdown(numbering: inout Numbering) -> String? {
    switch self {
    case let .heading(level, text):
      _ = numbering.next(level: 0, style: nil)
      let body = text.markdown(continuation: "\\\n")
      return String(repeating: "#", count: level) + (body.isEmpty ? "" : " " + body)
    case let .paragraph(text):
      _ = numbering.next(level: 0, style: nil)
      return text.isEmpty ? nil : text.markdown(continuation: "\n")
    case let .list(level, style, text):
      let number = numbering.next(level: level, style: style)
      let indent = String(repeating: " ", count: 4 * level)
      let marker = switch style {
      case .unordered: "-"
      case .ordered: "\(number)."
      case .todo: "- [ ]"
      case .done: "- [x]"
      }
      let body = text.markdown(continuation: "\n" + indent + "    ")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.allSatisfy { $0 == " " } ? "" : $0 }
        .joined(separator: "\n")
      return indent + marker + (body.isEmpty ? "" : " " + body)
    case let .code(code):
      _ = numbering.next(level: 0, style: nil)
      let fence = fence(for: code)
      return fence + "\n" + (code.isEmpty ? "" : code + "\n") + fence
    case let .view(view, config, sql):
      _ = numbering.next(level: 0, style: nil)
      let body = "{\"view\":" + JSONValue.string(view).jsonString() + ",\"config\":" + config.jsonString(sortedKeys: true)
        + ",\"sql\":" + JSONValue.string(sql).jsonString() + "}"
      let fence = fence(for: body)
      return fence + "wuhu-view\n" + body + "\n" + fence
    }
  }
}

private func fence(for code: String) -> String {
  var longest = 0
  var run = 0
  for character in code {
    run = character == "`" ? run + 1 : 0
    longest = max(longest, run)
  }
  return String(repeating: "`", count: max(3, longest + 1))
}

extension Inline {
  /// Every change of marks closes all and reopens bold outside italic, the one spelling the parser
  /// reads back without guessing; a link closes the marks around both of its brackets.
  func markdown(continuation: String) -> String {
    var out = ""
    var current = Marks()
    var atLineStart = true
    func transition(to next: Marks) {
      if current.italic { out += "*" }
      if current.bold { out += "**" }
      if current.link != next.link {
        if let link = current.link { out += "](" + escapeURL(link) + ")" }
        if next.link != nil { out += "[" }
      }
      if next.bold { out += "**" }
      if next.italic { out += "*" }
      current = next
    }
    for run in self.runs {
      if run.marks != current { transition(to: run.marks) }
      out += escape(run.text, continuation: continuation, atLineStart: &atLineStart)
    }
    transition(to: Marks())
    return out
  }
}

private func escapeURL(_ url: String) -> String {
  var out = ""
  for character in url {
    if character == "\\" || character == ")" || character == "(" { out.append("\\") }
    out.append(character)
  }
  return out
}

private let lineStartSpecials: Set<Character> = ["#", "-", "+", ">", "|", "`", "~", "=", " ", "\t"]

private func escape(_ text: String, continuation: String, atLineStart: inout Bool) -> String {
  var out = ""
  let characters = Array(text)
  var index = 0
  while index < characters.count {
    let character = characters[index]
    defer { index += 1 }
    if character == "\n" {
      out += continuation
      atLineStart = true
      continue
    }
    if atLineStart {
      atLineStart = false
      if lineStartSpecials.contains(character) || startsThematicUnderscores(characters, at: index) {
        out += "\\" + String(character)
        continue
      }
      if character.isASCII, character.isNumber {
        var end = index
        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
        out += String(characters[index ..< end])
        if end < characters.count, characters[end] == "." || characters[end] == ")" {
          out += "\\" + String(characters[end])
          end += 1
        }
        index = end - 1
        continue
      }
    }
    switch character {
    case "\\", "*", "[", "]":
      out += "\\" + String(character)
    case "<" where index + 1 < characters.count && opensTag(characters[index + 1]):
      out += "\\<"
    default:
      out.append(character)
    }
  }
  return out
}

private func startsThematicUnderscores(_ characters: [Character], at index: Int) -> Bool {
  index + 2 < characters.count && characters[index ... index + 2].allSatisfy { $0 == "_" }
}

func opensTag(_ character: Character) -> Bool {
  character.isASCII && (character.isLetter || character == "/" || character == "!" || character == "?")
}

private func frontmatterLines(key: String, value: JSONValue) -> String {
  if case let .array(items) = value, !items.isEmpty, items.allSatisfy(\.isScalar) {
    return key + ":\n" + items.map { "  - " + scalarYAML($0) + "\n" }.joined()
  }
  return key + ": " + scalarYAML(value) + "\n"
}

extension JSONValue {
  var isScalar: Bool {
    switch self {
    case .array, .object: false
    default: true
    }
  }
}

func scalarYAML(_ value: JSONValue) -> String {
  switch value {
  case .null: "null"
  case let .bool(flag): flag ? "true" : "false"
  case let .integer(number): String(number)
  case let .number(number): number.isFinite ? yamlDouble(number) : "null"
  case let .string(string): isPlainSafe(string) ? string : JSONValue.string(string).jsonString()
  case .array, .object: value.jsonString(sortedKeys: true)
  }
}

private func yamlDouble(_ number: Double) -> String {
  let text = "\(number)"
  return text.contains(".") || text.contains("e") ? text : text + ".0"
}

/// A plain YAML scalar that reads back as this same string.
func isPlainSafe(_ string: String) -> Bool {
  guard let first = string.first, let last = string.last else { return false }
  if first == " " || last == " " { return false }
  if "[]{}&*!|>%@`\"'#,?:-".contains(first) { return false }
  if string.contains(": ") || string.contains(" #") || string.hasSuffix(":") { return false }
  if string.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
  if case .string = yamlScalar(string) { return true }
  return false
}
