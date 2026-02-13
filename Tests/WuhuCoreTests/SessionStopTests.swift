import Foundation
import Testing
import WuhuAPI
import WuhuCore

struct SessionStopTests {
  private func newSessionID() -> String {
    UUID().uuidString.lowercased()
  }

  @Test func stopSession_noopWhenIdle() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let response = try await service.stopSession(sessionID: session.id, user: "alice")
    #expect(response.stopEntry == nil)
    #expect(response.repairedEntries.isEmpty)
  }

  @Test func stopSession_appendsStopMessageWhenTranscriptLooksExecuting() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    _ = try await store.appendEntry(sessionID: session.id, payload: .message(.user(.init(
      user: "alice",
      content: [.text(text: "Hello", signature: nil)],
      timestamp: Date(),
    ))))

    let response = try await service.stopSession(sessionID: session.id, user: "alice")
    #expect(response.stopEntry != nil)

    let transcript = try await store.getEntries(sessionID: session.id)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)
    #expect(inferred.state == .stopped)
  }

  @Test func stopSession_repairsMissingToolResultsWithStoppedReason() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      sessionID: newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: .init(name: "test", type: .local, path: "/tmp"),
    )

    let now = Date(timeIntervalSince1970: 0)
    _ = try await store.appendEntry(sessionID: session.id, payload: .message(.assistant(.init(
      provider: .openai,
      model: "mock",
      content: [.toolCall(id: "t1", name: "bash", arguments: .object([:]))],
      usage: nil,
      stopReason: "stop",
      errorMessage: nil,
      timestamp: now,
    ))))

    let response = try await service.stopSession(sessionID: session.id, user: "alice")
    #expect(response.stopEntry != nil)

    let transcript = try await store.getEntries(sessionID: session.id)
    let repairedToolResult = transcript.first(where: { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == "t1"
    })
    #expect(repairedToolResult != nil)

    if let repairedToolResult,
       case let .message(.toolResult(t)) = repairedToolResult.payload
    {
      let text = t.content.compactMap { block -> String? in
        guard case let .text(text, _) = block else { return nil }
        return text
      }.joined(separator: "\n")
      #expect(text.contains("Execution was stopped"))
      #expect(t.details.object?["reason"]?.stringValue == "stopped")
      #expect(t.isError == true)
    }
  }
}
