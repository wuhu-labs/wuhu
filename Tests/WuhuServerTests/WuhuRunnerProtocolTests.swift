import Foundation
import Testing
import WuhuAPI

struct WuhuRunnerProtocolTests {
  @Test func runnerMessageJSONRoundTrip() throws {
    let toolResult = WuhuToolResult(
      content: [.text(text: "ok", signature: nil)],
      details: .object(["exitCode": .number(0)]),
    )

    let messages: [WuhuRunnerMessage] = [
      .hello(runnerName: "vps-in-la", version: 1),
      .resolveEnvironmentRequest(id: "req-1", sessionID: "sess-1", name: "repo"),
      .resolveEnvironmentResponse(
        id: "req-1",
        environment: .init(name: "repo", type: .local, path: "/tmp/repo"),
        error: nil,
      ),
      .registerSession(sessionID: "sess-1", environment: .init(name: "repo", type: .local, path: "/tmp/repo")),
      .toolRequest(
        id: "req-2",
        sessionID: "sess-1",
        toolCallId: "tool-1",
        toolName: "ls",
        args: .object(["path": .string("."), "limit": .number(20)]),
      ),
      .toolResponse(
        id: "req-2",
        sessionID: "sess-1",
        toolCallId: "tool-1",
        result: toolResult,
        isError: false,
        errorMessage: nil,
      ),
      .toolResponse(
        id: "req-3",
        sessionID: "sess-1",
        toolCallId: "tool-2",
        result: nil,
        isError: true,
        errorMessage: "Unknown tool",
      ),
    ]

    for message in messages {
      let data = try WuhuJSON.encoder.encode(message)
      let decoded = try WuhuJSON.decoder.decode(WuhuRunnerMessage.self, from: data)
      #expect(decoded == message)
    }
  }
}
