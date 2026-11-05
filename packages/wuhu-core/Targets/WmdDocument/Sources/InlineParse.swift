extension Inline {
  /// Reads `**bold**`, `*italic*`, `[text](url)`, `` `code` `` and backslash escapes; `line` is
  /// where `markdown` starts in the agent's text.
  public init(markdown: String, line: Int) throws(WmdSyntaxError) {
    var reader = InlineReader(Array(markdown), line: line)
    self = try reader.read()
  }
}

private enum Emphasis: Equatable {
  case bold
  case italic
}

private struct InlineReader {
  let characters: [Character]
  let firstLine: Int
  var index = 0
  var stack: [Emphasis] = []
  var result = Inline()
  /// Runs inside an open `[`, waiting for the url its `](…)` names.
  var linked: [InlineRun]?
  var linkLine = 0

  init(_ characters: [Character], line: Int) {
    self.characters = characters
    self.firstLine = line
  }

  var line: Int { self.firstLine + self.characters[..<min(self.index, self.characters.count)].count { $0 == "\n" } }

  func failure(_ problem: WmdSyntaxError.Problem, line: Int? = nil) -> WmdSyntaxError {
    WmdSyntaxError(line: line ?? self.line, problem: problem)
  }

  mutating func literal(_ character: Character) {
    self.add(InlineRun(text: String(character), marks: .text(bold: self.stack.contains(.bold), italic: self.stack.contains(.italic))))
  }

  mutating func add(_ run: InlineRun) {
    if self.linked != nil { self.linked!.append(run) } else { self.result.append(run) }
  }

  mutating func read() throws(WmdSyntaxError) -> Inline {
    while self.index < self.characters.count {
      let character = self.characters[self.index]
      let next = self.index + 1 < self.characters.count ? self.characters[self.index + 1] : nil
      switch character {
      case "\\":
        if let next, next == "\n" || next == " " || next == "\t" || (next.isASCII && next.isPunctuation) || (next.isASCII && next.isSymbol) {
          self.literal(next)
          self.index += 2
        } else {
          self.literal(character)
          self.index += 1
        }
      case "*":
        var count = 0
        while self.index < self.characters.count, self.characters[self.index] == "*" {
          count += 1
          self.index += 1
        }
        try self.emphasis(count)
      case "`":
        self.code()
      case "!" where next == "[":
        throw self.failure(.image)
      case "[":
        guard self.linked == nil else { throw self.failure(.nestedLink) }
        self.linked = []
        self.linkLine = self.line
        self.index += 1
      case "]":
        try self.closeLink()
      case "<" where next.map(opensTag) == true:
        throw self.failure(.html)
      default:
        self.literal(character)
        self.index += 1
      }
    }
    if self.linked != nil { throw self.failure(.unclosedLink, line: self.linkLine) }
    guard self.stack.isEmpty else { throw self.failure(.unclosedEmphasis, line: self.firstLine) }
    return self.result
  }

  /// A run of stars first closes what is open from the top, then opens bold before italic; the
  /// renderer only ever writes runs this reading takes apart unambiguously.
  mutating func emphasis(_ count: Int) throws(WmdSyntaxError) {
    var left = count
    while left > 0 {
      switch self.stack.last {
      case .italic?:
        self.stack.removeLast()
        left -= 1
      case .bold? where left >= 2:
        self.stack.removeLast()
        left -= 2
      default:
        if left >= 2, !self.stack.contains(.bold) {
          self.stack.append(.bold)
          left -= 2
        } else if !self.stack.contains(.italic) {
          self.stack.append(.italic)
          left -= 1
        } else {
          throw self.failure(.overlappingEmphasis)
        }
      }
    }
  }

  /// A run of n backticks opens code that the next run of exactly n closes, a newline inside
  /// staying outside the mark; with no such run, it is literal.
  mutating func code() {
    let fence = self.backticks(at: self.index)
    var close = self.index + fence
    while close < self.characters.count, self.characters[close] != "`" || self.backticks(at: close) != fence {
      close += self.characters[close] == "`" ? self.backticks(at: close) : 1
    }
    guard close < self.characters.count else {
      for _ in 0 ..< fence { self.literal("`") }
      self.index += fence
      return
    }
    var code = self.characters[self.index + fence ..< close]
    if code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) { code = code.dropFirst().dropLast() }
    for (number, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      if number > 0 { self.literal("\n") }
      self.add(InlineRun(text: String(line), marks: .code))
    }
    self.index = close + fence
  }

  func backticks(at start: Int) -> Int {
    self.characters[start...].prefix { $0 == "`" }.count
  }

  mutating func closeLink() throws(WmdSyntaxError) {
    guard let runs = self.linked else { throw self.failure(.strayBracket) }
    self.index += 1
    guard self.index < self.characters.count, self.characters[self.index] == "(" else {
      throw self.failure(.unclosedLink, line: self.linkLine)
    }
    self.index += 1
    var url = ""
    while true {
      guard self.index < self.characters.count, self.characters[self.index] != "\n" else {
        throw self.failure(.unclosedLink, line: self.linkLine)
      }
      let character = self.characters[self.index]
      self.index += 1
      if character == ")" { break }
      if character == "\\", self.index < self.characters.count, self.characters[self.index] != "\n" {
        url.append(self.characters[self.index])
        self.index += 1
        continue
      }
      url.append(character)
    }
    self.linked = nil
    for run in runs {
      guard case let .text(bold, italic, _) = run.marks else {
        self.result.append(run)
        continue
      }
      self.result.append(InlineRun(text: run.text, marks: .text(bold: bold, italic: italic, link: url)))
    }
  }
}
