import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCLIKit

struct SessionOutputTests {
  @Test func toolSummary_compactBashIsSingleLinePrefix() {
    let args: JSONValue = .object([
      "command": .string("echo hi\ncat README.md | head -n 5\n"),
    ])

    let line = toolSummaryLine(
      .init(toolName: "bash", args: args, result: nil, isError: false),
      verbosity: .compact,
    )

    #expect(line.hasPrefix("bash "))
    #expect(!line.contains("\n"))
    #expect(line.contains("echo hi"))
  }

  @Test func transcript_fullDoesNotInlineReadFileContents() {
    let now = Date(timeIntervalSince1970: 0)
    let session = WuhuSession(
      id: "s1",
      provider: .openai,
      model: "gpt-test",
      environment: .init(name: "local", type: .local, path: "/tmp"),
      cwd: "/repo",
      parentSessionID: nil,
      createdAt: now,
      updatedAt: now,
      headEntryID: 1,
      tailEntryID: 4,
    )

    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        content: [.text(text: "Please read the file.", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: "t1",
        toolName: "read",
        arguments: .object(["path": .string("secret.txt")]),
      ))),
      .init(id: 3, sessionID: "s1", parentEntryID: 2, createdAt: now, payload: .toolExecution(.init(
        phase: .end,
        toolCallId: "t1",
        toolName: "read",
        arguments: .null,
        result: .object([
          "content": .array([.object(["type": .string("text"), "text": .string("SECRET\nSECRET\nSECRET"), "signature": .null])]),
          "details": .object([:]),
        ]),
        isError: false,
      ))),
      .init(id: 4, sessionID: "s1", parentEntryID: 3, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.text(text: "Done.", signature: nil)],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    let response = WuhuGetSessionResponse(session: session, transcript: entries)

    let terminal = TerminalCapabilities(stdoutIsTTY: false, stderrIsTTY: false, colorEnabled: false)
    let style = SessionOutputStyle(verbosity: .full, terminal: terminal)
    let renderer = SessionTranscriptRenderer(style: style)
    let output = renderer.render(response)

    #expect(output.contains("Tool: read secret.txt"))
    #expect(!output.contains("SECRET"))
  }

  @Test func transcript_minimalGroupsTools() {
    let now = Date(timeIntervalSince1970: 0)
    let session = WuhuSession(
      id: "s1",
      provider: .openai,
      model: "gpt-test",
      environment: .init(name: "local", type: .local, path: "/tmp"),
      cwd: "/repo",
      parentSessionID: nil,
      createdAt: now,
      updatedAt: now,
      headEntryID: 1,
      tailEntryID: 4,
    )

    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        content: [.text(text: "Hi", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: "t1",
        toolName: "bash",
        arguments: .object(["command": .string("echo hi")]),
      ))),
      .init(id: 3, sessionID: "s1", parentEntryID: 2, createdAt: now, payload: .toolExecution(.init(
        phase: .end,
        toolCallId: "t1",
        toolName: "bash",
        arguments: .null,
        result: .object([
          "content": .array([.object(["type": .string("text"), "text": .string("hi"), "signature": .null])]),
          "details": .object([:]),
        ]),
        isError: false,
      ))),
      .init(id: 4, sessionID: "s1", parentEntryID: 3, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.text(text: "ok", signature: nil)],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    let response = WuhuGetSessionResponse(session: session, transcript: entries)

    let terminal = TerminalCapabilities(stdoutIsTTY: false, stderrIsTTY: false, colorEnabled: false)
    let style = SessionOutputStyle(verbosity: .minimal, terminal: terminal)
    let renderer = SessionTranscriptRenderer(style: style)
    let output = renderer.render(response)

    #expect(output.contains("Executed 1 tool"))
    #expect(!output.contains("Tool:"))
    #expect(!output.contains("bash echo hi"))
  }
}
