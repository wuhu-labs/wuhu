import Foundation
import Testing
import WuhuAPI

struct WuhuSessionTranscriptFormattingTests {
  @Test func minimal_groupsToolsAndHidesToolOutput() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        user: "alice",
        content: [.text(text: "Hi", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .message(.toolResult(.init(
        toolCallId: "call_123",
        toolName: "read",
        content: [.text(text: "SECRET\nSECRET\nSECRET", signature: nil)],
        details: .object([:]),
        isError: false,
        timestamp: now,
      )))),
      .init(id: 3, sessionID: "s1", parentEntryID: 2, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.text(text: "Done.", signature: nil)],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    let items = WuhuSessionTranscriptFormatter(verbosity: .minimal).format(entries)

    #expect(items.contains(where: { $0.role == .meta && $0.text.contains("Executed 1 tool") }))
    #expect(!items.contains(where: { $0.role == .tool }))
    #expect(!items.contains(where: { $0.text.contains("SECRET") }))
    #expect(items.contains(where: { $0.role == .user && $0.title == "User:" }))
    #expect(items.contains(where: { $0.role == .agent && $0.title == "Agent:" }))
  }

  @Test func compact_toolLinesHideIdsAndJson() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        user: "alice",
        content: [.text(text: "Run stuff", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: "call_abc",
        toolName: "bash",
        arguments: .object(["command": .string("echo hi\ncat README.md | head -n 5\n")]),
      ))),
      .init(id: 3, sessionID: "s1", parentEntryID: 2, createdAt: now, payload: .message(.toolResult(.init(
        toolCallId: "call_abc",
        toolName: "bash",
        content: [.text(text: "hi", signature: nil)],
        details: .object([:]),
        isError: false,
        timestamp: now,
      )))),
    ]

    let items = WuhuSessionTranscriptFormatter(verbosity: .compact).format(entries)
    let toolText = items.first(where: { $0.role == .tool })?.text ?? ""

    #expect(toolText.hasPrefix("bash "))
    #expect(!toolText.contains("\n"))
    #expect(!toolText.contains("call_"))
    #expect(!toolText.contains("{"))
  }

  @Test func full_truncatesToolOutputAndHidesReadContents() {
    let now = Date(timeIntervalSince1970: 0)
    let longOutput = (0 ..< 80).map { "line \($0)" }.joined(separator: "\n")
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: "call_read",
        toolName: "read",
        arguments: .object(["path": .string("secret.txt")]),
      ))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .message(.toolResult(.init(
        toolCallId: "call_read",
        toolName: "read",
        content: [.text(text: "SECRET", signature: nil)],
        details: .object([:]),
        isError: false,
        timestamp: now,
      )))),
      .init(id: 3, sessionID: "s1", parentEntryID: 2, createdAt: now, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: "call_bash",
        toolName: "bash",
        arguments: .object(["command": .string("python -c 'print(123)'")]),
      ))),
      .init(id: 4, sessionID: "s1", parentEntryID: 3, createdAt: now, payload: .message(.toolResult(.init(
        toolCallId: "call_bash",
        toolName: "bash",
        content: [.text(text: longOutput, signature: nil)],
        details: .object([:]),
        isError: false,
        timestamp: now,
      )))),
    ]

    let items = WuhuSessionTranscriptFormatter(verbosity: .full).format(entries)

    let readTool = items.first(where: { $0.role == .tool && $0.text.contains("read secret.txt") })?.text ?? ""
    #expect(!readTool.contains("SECRET"))

    let bashTool = items.first(where: { $0.role == .tool && $0.text.hasPrefix("bash ") })?.text ?? ""
    #expect(bashTool.contains("[truncated]"))
  }

  @Test func assistantMessagesAreNeverTruncated() {
    let now = Date(timeIntervalSince1970: 0)
    let longMessage = (0 ..< 80).map { "line \($0)" }.joined(separator: "\n")
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.text(text: longMessage, signature: nil)],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    for verbosity in [WuhuSessionVerbosity.minimal, .compact, .full] {
      let items = WuhuSessionTranscriptFormatter(verbosity: verbosity).format(entries)
      let agentText = items.first(where: { $0.role == .agent })?.text ?? ""
      #expect(!agentText.contains("[truncated]"))
      #expect(agentText.contains("line 79"))
    }
  }
}
