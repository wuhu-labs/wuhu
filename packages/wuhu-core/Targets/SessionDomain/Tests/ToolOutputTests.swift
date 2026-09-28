import SessionDomain
import Testing

@Suite struct ToolOutputClampTests {
  @Test func underBudgetPassesThrough() {
    let content = "one\ntwo\nthree"
    let clamp = ToolOutput.head(content)
    #expect(clamp.text == content)
    #expect(!clamp.clamped)
    #expect(clamp.shownLines == 1 ... 3)
    #expect(clamp.totalLines == 3)
    #expect(clamp.totalBytes == content.utf8.count)
  }

  @Test func headClampsByLines() {
    let content = (1 ... 10).map { "line-\($0)" }.joined(separator: "\n")
    let clamp = ToolOutput.head(content, maxLines: 4, maxBytes: 1 << 20)
    #expect(clamp.text == "line-1\nline-2\nline-3\nline-4")
    #expect(clamp.clamped)
    #expect(clamp.shownLines == 1 ... 4)
    #expect(clamp.totalLines == 10)
  }

  @Test func headClampsByBytesOnWholeLines() {
    let content = "aaaa\nbbbb\ncccc"
    // 4 + 1+4 = 9 fits; the third line would need 14.
    let clamp = ToolOutput.head(content, maxLines: 100, maxBytes: 9)
    #expect(clamp.text == "aaaa\nbbbb")
    #expect(clamp.clamped)
    #expect(clamp.shownLines == 1 ... 2)
  }

  @Test func headShowsOversizedFirstLinePartially() {
    let content = String(repeating: "x", count: 100) + "\nrest"
    let clamp = ToolOutput.head(content, maxLines: 10, maxBytes: 25)
    #expect(clamp.text == String(repeating: "x", count: 25))
    #expect(clamp.clamped)
    #expect(clamp.shownLines == nil)
  }

  @Test func byteClampNeverSplitsACodePoint() {
    let content = String(repeating: "字", count: 30) // 3 bytes each
    let clamp = ToolOutput.head(content, maxLines: 10, maxBytes: 32)
    #expect(clamp.text == String(repeating: "字", count: 10))
    #expect(clamp.text.utf8.count <= 32)
  }

  @Test func tailKeepsTheEnd() {
    let content = (1 ... 10).map { "line-\($0)" }.joined(separator: "\n")
    let clamp = ToolOutput.tail(content, maxLines: 3, maxBytes: 1 << 20)
    #expect(clamp.text == "line-8\nline-9\nline-10")
    #expect(clamp.clamped)
    #expect(clamp.shownLines == 8 ... 10)
    #expect(clamp.totalLines == 10)
  }

  @Test func tailShowsOversizedLastLinePartially() {
    let content = "head\n" + String(repeating: "y", count: 100)
    let clamp = ToolOutput.tail(content, maxLines: 10, maxBytes: 25)
    #expect(clamp.text == String(repeating: "y", count: 25))
    #expect(clamp.shownLines == nil)
    #expect(clamp.clamped)
  }

  @Test func emptyContentIsUnclamped() {
    let clamp = ToolOutput.head("")
    #expect(clamp.text.isEmpty)
    #expect(!clamp.clamped)
  }

  @Test func matchedLineClamp() {
    #expect(ToolOutput.clampedLine("short") == "short")
    let long = String(repeating: "m", count: 600)
    let clamped = ToolOutput.clampedLine(long)
    #expect(clamped.hasPrefix(String(repeating: "m", count: 500)))
    #expect(clamped.hasSuffix("[line clamped: 600 bytes]"))
  }
}

@Suite struct ToolResultBackstopTests {
  @Test func oversizedReadContentIsBackstopped() {
    let payload = ToolResultPayload.read(.init(
      path: "/big.txt",
      revision: .journal(1),
      content: String(repeating: "z", count: 2000),
    ))
    guard case let .read(result) = payload.clamped(limit: 100) else {
      Issue.record("payload changed case")
      return
    }
    #expect(result.content.utf8.count < 300)
    #expect(result.content.contains("[kernel backstop: tool result was 2000 bytes"))
  }

  @Test func modestPayloadsPassUntouched() {
    let payload = ToolResultPayload.exec(.init(output: "fine", exitCode: 0))
    #expect(payload.clamped(limit: 100) == payload)
  }

  @Test func failureMessagesAreBackstopped() {
    let payload = ToolResultPayload.failure(.init(message: String(repeating: "e", count: 500)))
    guard case let .failure(failure) = payload.clamped(limit: 100) else {
      Issue.record("payload changed case")
      return
    }
    #expect(failure.message.utf8.count < 300)
  }
}
