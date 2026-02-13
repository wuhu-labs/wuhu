import Foundation
import Testing
import WuhuAPI

struct WuhuSessionExecutionInferenceTests {
  @Test func infer_executingWhenLastMessageIsUser() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        user: "alice",
        content: [.text(text: "Hi", signature: nil)],
        timestamp: now,
      )))),
    ]

    let inferred = WuhuSessionExecutionInference.infer(from: entries)
    #expect(inferred.state == .executing)
  }

  @Test func infer_idleWhenAssistantRespondedWithoutToolCalls() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        user: "alice",
        content: [.text(text: "Hi", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.text(text: "Hello.", signature: nil)],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    let inferred = WuhuSessionExecutionInference.infer(from: entries)
    #expect(inferred.state == .idle)
  }

  @Test func infer_executingWhenAssistantEmitsToolCallWithoutResult() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.toolCall(id: "t1", name: "read", arguments: .object([:]))],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
    ]

    let inferred = WuhuSessionExecutionInference.infer(from: entries)
    #expect(inferred.state == .executing)
    #expect(inferred.pendingToolCallIds.contains("t1"))
  }

  @Test func infer_stoppedWhenStopMarkerIsLast() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.user(.init(
        user: "alice",
        content: [.text(text: "Do a thing", signature: nil)],
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .message(.customMessage(.init(
        customType: WuhuCustomMessageTypes.executionStopped,
        content: [.text(text: "Execution stopped", signature: nil)],
        details: .object([:]),
        display: true,
        timestamp: now,
      )))),
    ]

    let inferred = WuhuSessionExecutionInference.infer(from: entries)
    #expect(inferred.state == .stopped)
    #expect(inferred.pendingToolCallIds.isEmpty)
    #expect(inferred.pendingToolExecutionIds.isEmpty)
  }

  @Test func infer_stopMarkerClearsPendingToolCalls() {
    let now = Date(timeIntervalSince1970: 0)
    let entries: [WuhuSessionEntry] = [
      .init(id: 1, sessionID: "s1", parentEntryID: nil, createdAt: now, payload: .message(.assistant(.init(
        provider: .openai,
        model: "gpt-test",
        content: [.toolCall(id: "t1", name: "bash", arguments: .object([:]))],
        usage: nil,
        stopReason: "stop",
        errorMessage: nil,
        timestamp: now,
      )))),
      .init(id: 2, sessionID: "s1", parentEntryID: 1, createdAt: now, payload: .message(.customMessage(.init(
        customType: WuhuCustomMessageTypes.executionStopped,
        content: [.text(text: "Execution stopped", signature: nil)],
        details: nil,
        display: true,
        timestamp: now,
      )))),
    ]

    let inferred = WuhuSessionExecutionInference.infer(from: entries)
    #expect(inferred.state == .stopped)
    #expect(inferred.pendingToolCallIds.isEmpty)
  }
}
