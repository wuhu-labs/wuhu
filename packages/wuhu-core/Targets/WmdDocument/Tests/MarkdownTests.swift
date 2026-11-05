import Testing
@testable import WmdDocument

@Suite struct MarkdownTests {
  static let canonical = """
  ---
  owner: minsheng
  tags:
    - draft
    - "two words: yes"
  version: 3
  ---

  # Title with **bold** and *italic*

  A paragraph with a [link](https://example.com/a\\(b\\)) and ***both*** marks.
  \\# not a heading, # mid-line, 1. mid-line, \\[x\\] \\* \\\\ \\<b> a < b.
  \\- not a list
  1\\. not ordered
  \\`\\`\\`not a fence, `code`, ``a`b``, `` `x` ``, `` ` ``, ` `, **bold `c` text** and [link `d`](u).

  ## Lists

  - first
  - [ ] todo with *style*
      - [x] done, nested
          continued line of the done item
          1. deep
          2. deeper
  1. one
  2. two

  ### Code and `spans`

  ````
  let fence = ```
    indented
  ````

  ```wuhu-view
  {"view":"kanban","config":{"cardTitle":"title","groupBy":"status"},"sql":"SELECT status, title FROM \\"/tasks.table\\""}
  ```

  #

  -

  """

  @Test func canonicalTextIsAFixedPoint() throws {
    let output = try WmdMarkdown.canonical(Self.canonical)
    let got = output.split(separator: "\n", omittingEmptySubsequences: false)
    let want = Self.canonical.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in want.enumerated() where index >= got.count || got[index] != line {
      Issue.record("line \(index + 1): got \(index < got.count ? String(reflecting: String(got[index])) : "nothing"), want \(String(reflecting: String(line)))")
    }
    #expect(got.count == want.count)
  }

  @Test(arguments: [
    ("5. a\n9. b\n", "1. a\n2. b\n"),
    ("a\n   b\n", "a\nb\n"),
    ("# T\npara\n", "# T\n\npara\n"),
    ("---\nb: 1\na: x\n---\n", "---\na: x\nb: 1\n---\n"),
    ("**[a](u)**\n", "[**a**](u)\n"),
    ("**a*b***\n", "**a*****b***\n"),
    ("- [X] x\n", "- [x] x\n"),
    ("\\q\n", "\\\\q\n"),
    ("x\n\n\n\ny\n", "x\n\ny\n"),
    ("- a\n\n- b\n", "- a\n- b\n"),
    ("- a\n\n\n    b\n", "- a\n\n\n    b\n"),
    ("- a\n    - b\n\n        c\n- d\n", "- a\n    - b\n\n        c\n- d\n"),
    ("`a\nb`\n", "`a`\n`b`\n"),
    ("` a `\n", "`a`\n"),
    ("a ` b ``c`\n", "a ` b ``c`\n"),
    ("```x``` y\n", "`x` y\n"),
    ("*a `*` b*\n", "*a `*` b*\n"),
    ("`\\*`\n", "`\\*`\n"),
    ("\\`x\\`\n", "`x`\n"),
  ])
  func normalizes(_ input: String, _ expected: String) throws {
    let output = try WmdMarkdown.canonical(input)
    #expect(output == expected)
    #expect(try WmdMarkdown.canonical(output) == output)
  }

  @Test(arguments: [
    [InlineRun(text: "`"), InlineRun(text: "*", marks: .code)],
    [InlineRun(text: "a", marks: .code), InlineRun(text: "`")],
    [InlineRun(text: "a ` b "), InlineRun(text: "c", marks: .code)],
    [InlineRun(text: "``"), InlineRun(text: "`", marks: .code), InlineRun(text: "x\n`")],
  ])
  func literalBackticksBesideCodeRoundTrip(_ runs: [InlineRun]) throws {
    let text = Inline(runs)
    #expect(try Inline(markdown: text.markdown(continuation: "\n"), line: 1) == text)
  }

  @Test func textWithCodeRoundTrips() throws {
    var random = SplitMix(seed: 1)
    let pieces = ["a", " ", "`", "``", "*", "\\", "[", "]", "{", "\n"]
    for _ in 0 ..< 2000 {
      let runs = (0 ..< Int.random(in: 1 ... 5, using: &random)).map { _ in
        let code = Bool.random(using: &random)
        let text = (0 ..< Int.random(in: 1 ... 4, using: &random)).map { _ in
          pieces[Int.random(in: 0 ..< pieces.count - (code ? 1 : 0), using: &random)]
        }.joined()
        let marks = code ? InlineMarks.code : .text(
          bold: Bool.random(using: &random),
          italic: Bool.random(using: &random),
          link: Bool.random(using: &random) ? "u" : nil,
        )
        return InlineRun(text: text, marks: marks)
      }
      let text = Inline(runs + [InlineRun(text: "c", marks: .code)])
      let markdown = text.markdown(continuation: "\n")
      #expect(try Inline(markdown: markdown, line: 1) == text, "\(markdown)")
    }
  }

  @Test(arguments: [
    ("ok\n\n<div>\n", 3, WmdSyntaxError.Problem.html),
    ("a\n| x | y |\n", 2, .table),
    ("> quote\n", 1, .quote),
    ("see ![img](x.png)\n", 1, .image),
    ("a\n\n***\n", 3, .thematicBreak),
    ("Title\n===\n", 2, .setextHeading),
    ("#### deep\n", 1, .deepHeading(level: 4)),
    ("* item\n", 1, .listMarker("*")),
    ("1) item\n", 1, .listMarker("1)")),
    ("  - two spaces\n", 1, .listIndent(spaces: 2)),
    ("    code\n", 1, .indentedCode),
    ("~~~\nx\n~~~\n", 1, .tildeFence),
    ("x\n\n```swift\nlet a\n```\n", 3, .codeInfo("swift")),
    ("```\nnever closed\n", 1, .unclosedFence),
    ("a **bold\n", 1, .unclosedEmphasis),
    ("[a [b](c)](d)\n", 1, .nestedLink),
    ("a ] b\n", 1, .strayBracket),
    ("line one\n[a](b\nc)\n", 2, .unclosedLink),
    ("```wuhu-view\n{\"view\":\"list\"}\n```\n", 1, .view("keys must be exactly view, config and sql")),
    ("---\na: 1\n", 1, .unclosedFrontmatter),
    ("---\nnested:\n  key: 1\n---\n", 3, .frontmatter("expected key: value")),
  ])
  func refuses(_ input: String, _ line: Int, _ problem: WmdSyntaxError.Problem) {
    #expect(throws: WmdSyntaxError(line: line, problem: problem)) { try WmdMarkdown.canonical(input) }
  }
}

private struct SplitMix: RandomNumberGenerator {
  var seed: UInt64

  mutating func next() -> UInt64 {
    self.seed &+= 0x9E37_79B9_7F4A_7C15
    var z = self.seed
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
