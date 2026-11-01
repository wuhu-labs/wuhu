import JSONValue

/// A `.wmd` document as the agent view sees it: what the canonical markdown says, nothing more.
struct Content: Hashable {
  var frontmatter: [String: JSONValue] = [:]
  var blocks: [Block] = []
}

enum Block: Hashable {
  case heading(level: Int, text: Inline)
  case paragraph(Inline)
  case list(level: Int, style: ListStyle, text: Inline)
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

enum ListStyle: String, Hashable, CaseIterable {
  case unordered
  case ordered
  case todo
  case done
}

struct Marks: Hashable {
  var bold = false
  var italic = false
  var link: String?
}

struct Run: Hashable {
  var text: String
  var marks: Marks
}

/// Runs with no empty member and no two neighbours sharing marks, so equal text compares equal.
struct Inline: Hashable {
  private(set) var runs: [Run] = []

  init(_ runs: [Run] = []) {
    for run in runs { self.append(run) }
  }

  init(plain: String) {
    self.init([Run(text: plain, marks: Marks())])
  }

  mutating func append(_ run: Run) {
    guard !run.text.isEmpty else { return }
    if let last = self.runs.last, last.marks == run.marks {
      self.runs[self.runs.count - 1].text += run.text
    } else {
      self.runs.append(run)
    }
  }

  var plain: String { self.runs.map(\.text).joined() }
  var isEmpty: Bool { self.runs.isEmpty }
}
