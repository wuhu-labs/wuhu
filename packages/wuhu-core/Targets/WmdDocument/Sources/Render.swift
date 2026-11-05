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

  mutating func next(level: Int, style: WmdSchema.ListStyle?) -> Int {
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
  /// reads back without guessing; a link closes the marks around both of its brackets. Code sits
  /// inside whatever is open, as the parser gives it no other mark. Plain backticks are escaped
  /// only in text that has code, where a fence could take them. `escaping` adds characters
  /// written with a backslash outside code.
  public func markdown(continuation: String, escaping: Set<Character> = []) -> String {
    let textEscaping = self.runs.contains { $0.marks == .code } ? escaping.union(["`"]) : escaping
    var out = ""
    var current = (bold: false, italic: false, link: String?.none)
    var atLineStart = true
    func transition(bold: Bool, italic: Bool, link: String?) {
      if current.italic { out += "*" }
      if current.bold { out += "**" }
      if current.link != link {
        if let old = current.link { out += "](" + escapeURL(old, escaping: escaping) + ")" }
        if link != nil { out += "[" }
      }
      if bold { out += "**" }
      if italic { out += "*" }
      current = (bold, italic, link)
    }
    for run in self.runs {
      switch run.marks {
      case let .text(bold, italic, link):
        if current != (bold, italic, link) { transition(bold: bold, italic: italic, link: link) }
        out += escape(run.text, continuation: continuation, escaping: textEscaping, atLineStart: &atLineStart)
      case .code:
        for (number, line) in run.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
          if number > 0 {
            out += continuation
            atLineStart = true
          }
          guard !line.isEmpty else { continue }
          out += codeSpan(line)
          atLineStart = false
        }
      }
    }
    transition(bold: false, italic: false, link: nil)
    return out
  }
}

/// The shortest fence whose length no backtick run inside matches, padded where the code's own
/// edge would otherwise be read as part of the fence or stripped.
private func codeSpan(_ code: Substring) -> String {
  var runs: Set<Int> = []
  var run = 0
  for character in code + " " {
    if character == "`" {
      run += 1
    } else if run > 0 {
      runs.insert(run)
      run = 0
    }
  }
  let fence = String(repeating: "`", count: (1...).first { !runs.contains($0) }!)
  let padded = code.first == "`" || code.last == "`" || (code.first == " " && code.last == " " && code.contains { $0 != " " })
  return fence + (padded ? " " + code + " " : code) + fence
}

private func escapeURL(_ url: String, escaping: Set<Character>) -> String {
  var out = ""
  for character in url {
    if character == "\\" || character == ")" || character == "(" || escaping.contains(character) { out.append("\\") }
    out.append(character)
  }
  return out
}

private let lineStartSpecials: Set<Character> = ["#", "-", "+", ">", "|", "~", "=", " ", "\t"]

private func escape(_ text: String, continuation: String, escaping: Set<Character>, atLineStart: inout Bool) -> String {
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
      if character == "`", !escaping.contains("`") {
        let fence = characters[index...].prefix { $0 == "`" }.count
        out += String(repeating: fence >= 3 ? "\\`" : "`", count: fence)
        index += fence - 1
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
      if escaping.contains(character) { out += "\\" }
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
