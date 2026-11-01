/// Reads `**bold**`, `*italic*`, `[text](url)` and backslash escapes; `line` is where `text` starts.
func inline(_ text: String, line: Int) throws(WmdSyntaxError) -> Inline {
  var reader = InlineReader(Array(text), line: line)
  return try reader.read()
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
  var linked: [Run]?
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
    let marks = Marks(bold: self.stack.contains(.bold), italic: self.stack.contains(.italic))
    let run = Run(text: String(character), marks: marks)
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
      var marks = run.marks
      marks.link = url
      self.result.append(Run(text: run.text, marks: marks))
    }
  }
}
