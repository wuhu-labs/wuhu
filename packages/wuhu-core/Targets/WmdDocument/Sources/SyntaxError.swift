/// Markdown outside the `.wmd` subset, refused rather than guessed at.
public struct WmdSyntaxError: Error, Hashable, Sendable, CustomStringConvertible {
  /// 1-based line of the agent's text.
  public let line: Int
  public let problem: Problem

  public init(line: Int, problem: Problem) {
    self.line = line
    self.problem = problem
  }

  public enum Problem: Hashable, Sendable {
    case html
    case table
    case quote
    case image
    case thematicBreak
    case setextHeading
    case deepHeading(level: Int)
    case listMarker(String)
    case listIndent(spaces: Int)
    case indentedCode
    case tildeFence
    case codeInfo(String)
    case unclosedFence
    case unclosedEmphasis
    case overlappingEmphasis
    case nestedLink
    case strayBracket
    case unclosedLink
    case view(String)
    case unclosedFrontmatter
    case frontmatter(String)
  }

  public var description: String {
    "line \(self.line): \(self.problem)"
  }
}

extension WmdSyntaxError.Problem: CustomStringConvertible {
  public var description: String {
    switch self {
    case .html: "HTML is not supported; write \\< for a literal <"
    case .table: "tables are not supported; write \\| at the start of a line for a literal |"
    case .quote: "block quotes are not supported; write \\> for a literal >"
    case .image: "images are not supported; write !\\[ for a literal ![]"
    case .thematicBreak: "horizontal rules are not supported"
    case .setextHeading: "underlined headings are not supported; use # , ## or ###"
    case let .deepHeading(level): "heading level \(level) is not supported; use # , ## or ###"
    case let .listMarker(marker): "list items start with - , 1. , - [ ] or - [x], not \(marker)"
    case let .listIndent(spaces): "list levels are 4 spaces each, found \(spaces)"
    case .indentedCode: "indented code is not supported; fence code with ```"
    case .tildeFence: "fence code with backticks, not ~~~"
    case let .codeInfo(info): "code fences take no info string (found \(info)); only wuhu-view is special"
    case .unclosedFence: "the code fence opened here is never closed"
    case .unclosedEmphasis: "* or ** opened in this block is never closed"
    case .overlappingEmphasis: "* and ** overlap; close the inner one first"
    case .nestedLink: "links cannot contain links"
    case .strayBracket: "a ] without a link; write \\[ and \\] for literal brackets"
    case .unclosedLink: "a link needs [text](url) on one line"
    case let .view(reason): "a wuhu-view block holds one JSON object {view, config, sql}: \(reason)"
    case .unclosedFrontmatter: "the frontmatter opened here is never closed by ---"
    case let .frontmatter(reason): "frontmatter: \(reason)"
    }
  }
}
