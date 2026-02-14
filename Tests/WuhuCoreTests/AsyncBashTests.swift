import Foundation
import PiAgent
import PiAI
import Testing
import WuhuAPI
import WuhuCore

struct AsyncBashTests {
  private func makeTempDir(prefix: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  private func firstText(_ blocks: [WuhuContentBlock]) -> String? {
    for b in blocks {
      if case let .text(text, _) = b { return text }
    }
    return nil
  }

  @Test func asyncBashAppendsCompletionMessageBeforeIdle() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let registry = WuhuAsyncBashRegistry()
    let service = WuhuService(store: store, asyncBashRegistry: registry)

    let dir = try makeTempDir(prefix: "wuhu-async-bash")
    let session = try await service.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: dir),
    )

    actor TurnCounter {
      var n = 0
      func next() -> Int {
        n += 1
        return n
      }
    }
    let turns = TurnCounter()

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "run async",
      user: "test",
      tools: nil,
      streamFn: { model, _, _ in
        let turn = await turns.next()
        if turn == 1 {
          return AsyncThrowingStream { continuation in
            let toolCall = ToolCall(
              id: "t_async_1",
              name: "async_bash",
              arguments: .object(["command": .string("sleep 0.2 && echo 'done'")]),
            )
            let assistant = AssistantMessage(
              provider: model.provider,
              model: model.id,
              content: [.toolCall(toolCall)],
              stopReason: .toolUse,
            )
            continuation.yield(.done(message: assistant))
            continuation.finish()
          }
        }

        return AsyncThrowingStream { continuation in
          Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let assistant = AssistantMessage(
              provider: model.provider,
              model: model.id,
              content: [.text("ok")],
              stopReason: .stop,
            )
            continuation.yield(.done(message: assistant))
            continuation.finish()
          }
        }
      },
    )

    var eventIndex = 0
    var completionIndex: Int?
    var idleIndex: Int?
    var completionJSON: [String: Any]?

    for try await event in stream {
      eventIndex += 1
      switch event {
      case let .entryAppended(entry):
        guard case let .message(.user(m)) = entry.payload else { break }
        guard let text = firstText(m.content) else { break }
        guard let data = text.data(using: .utf8) else { break }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
        guard obj["exit_code"] != nil, obj["stdout_file"] != nil, obj["stderr_file"] != nil else { break }
        completionIndex = eventIndex
        completionJSON = obj

      case .idle:
        idleIndex = eventIndex

      case .assistantTextDelta, .done:
        break
      }
    }

    #expect(completionIndex != nil)
    #expect(idleIndex != nil)
    if let completionIndex, let idleIndex {
      #expect(completionIndex < idleIndex)
    }

    let json = try #require(completionJSON)
    #expect(json["id"] != nil)
    #expect(json["started_at"] != nil)
    #expect(json["ended_at"] != nil)
    #expect(json["duration"] != nil)
    #expect(json["output"] != nil)
  }
}
