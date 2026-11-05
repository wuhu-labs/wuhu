import JSONValue

/// A `.wmd` document as the agent view sees it: what the canonical markdown says, nothing more.
struct Content: Hashable {
  var frontmatter: [String: JSONValue] = [:]
  var blocks: [Block] = []
}

enum Block: Hashable {
  case heading(level: Int, text: Inline)
  case paragraph(Inline)
  case list(level: Int, style: WmdSchema.ListStyle, text: Inline)
  case code(String)
  case view(view: String, config: JSONValue, sql: String)

  var kind: String {
    switch self {
    case let .heading(level, _): "h\(level)"
    case .paragraph: "paragraph"
    case .list: "list"
    case .code: "code"
    case .view: "view"
    }
  }

  var inline: Inline? {
    switch self {
    case let .heading(_, text), let .paragraph(text), let .list(_, _, text): text
    case .code, .view: nil
    }
  }
}

/// A run's marks: code text carries no other mark.
public enum InlineMarks: Hashable, Sendable {
  case text(bold: Bool = false, italic: Bool = false, link: String? = nil)
  case code
}

public struct InlineRun: Hashable, Sendable {
  public var text: String
  public var marks: InlineMarks

  public init(text: String, marks: InlineMarks = .text()) {
    self.text = text
    self.marks = marks
  }
}

/// Marked text, as a `.wmd` block or a canvas item holds it. Runs have no empty member and no two
/// neighbours share marks, so equal text compares equal.
public struct Inline: Hashable, Sendable {
  public private(set) var runs: [InlineRun] = []

  public init(_ runs: [InlineRun] = []) {
    for run in runs { self.append(run) }
  }

  public init(plain: String) {
    self.init([InlineRun(text: plain)])
  }

  public mutating func append(_ run: InlineRun) {
    guard !run.text.isEmpty else { return }
    if let last = self.runs.last, last.marks == run.marks {
      self.runs[self.runs.count - 1].text += run.text
    } else {
      self.runs.append(run)
    }
  }

  public var plain: String { self.runs.map(\.text).joined() }
  public var isEmpty: Bool { self.runs.isEmpty }
}
