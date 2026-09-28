import SpaceFS
import Testing

struct TextEditTests {
  @Test func `replaces a unique span`() {
    #expect(
      TextEdit.apply(content: "alpha beta gamma", old: "beta", new: "BETA")
        == .success("alpha BETA gamma"),
    )
  }

  @Test func `missing old text fails as not found`() {
    #expect(
      TextEdit.apply(content: "alpha", old: "zeta", new: "x")
        == .failure(.notFound),
    )
  }

  @Test func `an ambiguous span fails with the occurrence count`() {
    #expect(
      TextEdit.apply(content: "x x x", old: "x", new: "y")
        == .failure(.notUnique(count: 3)),
    )
  }

  @Test func `an identical replacement fails as no change`() {
    #expect(
      TextEdit.apply(content: "hello", old: "hello", new: "hello")
        == .failure(.noChange),
    )
  }

  @Test func `an exact-unique needle whose fuzzy form repeats still replaces`() {
    #expect(
      TextEdit.apply(content: "foo \nfoo\n", old: "foo \n", new: "BAR\n")
        == .success("BAR\nfoo\n"),
    )
  }

  @Test func `the replacement lands on the exact span, not a fuzzy-collapsed sibling`() {
    #expect(
      TextEdit.apply(content: "foo \nfoo\n", old: "foo\n", new: "BAR\n")
        == .success("foo \nBAR\n"),
    )
  }

  @Test func `trailing whitespace is tolerated when matching`() {
    #expect(TextEdit.apply(
      content: "line one   \nline two  \nline three\n",
      old: "line one\nline two\n",
      new: "replaced\n",
    ) == .success("replaced\nline three\n"))
  }

  @Test func `a fuzzy edit rewrites only the matched span`() {
    let content = "smart “quotes” — stay\ntrailing spaces stay  \nfinal – result\nplain tail\n"
    let edited = TextEdit.apply(content: content, old: "final - result", new: "DONE")
    guard case let .success(output) = edited else {
      Issue.record("expected success, got \(edited)")
      return
    }
    #expect(output == "smart “quotes” — stay\ntrailing spaces stay  \nDONE\nplain tail\n")
    #expect(Array(output.utf8)[...20] == Array(content.utf8)[...20])
  }

  @Test func `a fuzzy edit whose span ends mid-line keeps the line's trailing whitespace`() {
    #expect(TextEdit.apply(
      content: "value – kept  \nnext\n",
      old: "value - kept",
      new: "value: kept",
    ) == .success("value: kept  \nnext\n"))
  }

  @Test func `ambiguity is counted in the fuzzy space when the match is fuzzy`() {
    #expect(TextEdit.apply(
      content: "a–b\na–b\n",
      old: "a-b",
      new: "c",
    ) == .failure(.notUnique(count: 2)))
  }

  @Test func `CRLF line endings and a UTF-8 BOM are preserved`() {
    #expect(TextEdit.apply(
      content: "\u{FEFF}first\r\nsecond\r\nthird\r\n",
      old: "second\n",
      new: "REPLACED\n",
    ) == .success("\u{FEFF}first\r\nREPLACED\r\nthird\r\n"))
  }
}
