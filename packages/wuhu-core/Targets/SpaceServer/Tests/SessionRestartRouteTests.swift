import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import LoopCore
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Synchronization
import Testing
import enum WuhuAI.InferenceError

@Suite(.deterministicDependencies) struct SessionRestartRouteTests {
  @Test func aBareRestartKeepsTheSpecAndWipesTheTranscript() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      try await harness.store.markInterrupted(id)

      let out = try await harness.call(
        "/v1/session/\(id.rawValue)/restart", .null, as: SessionRestartOutput.self,
      )
      #expect(out.id == id.rawValue)
      #expect(out.generation == 1)
      #expect(out.executor == "kernel")
      #expect(out.model == "test-model")
      #expect(out.queued == nil)

      try await until("restarted") { try await harness.store.generationState(id).generation == 1 }
      let lines = try await harness.store.testLines(id)
      #expect(lines.map(\.key) == [LineKey.head, "head:note"], "a restarted generation holds only its head and note")
      let note = try #require(lines.first { $0.key == "head:note" }?.text)
      #expect(note.hasPrefix("Started over on kernel testing/test-model"))
      #expect(note.contains("Catch up from your box before acting"))
      #expect(note.contains("read-box skill"))
      #expect(note.contains("last 2–5 messages"))
      #expect(try await harness.store.record(id).hold == .normal)
    }
  }

  @Test func aTaskRestartNamesItsParentDMInsteadOfABox() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let parent = try await harness.createSession()
      let task = try await harness.store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: try await harness.store.record(parent).executor)
      _ = try await harness.call("/v1/session/\(task.rawValue)/restart", .null, as: SessionRestartOutput.self)
      try await until("restarted") { try await harness.store.generationState(task).generation == 1 }
      let note = try #require(await harness.store.generationState(task).note)
      #expect(note.contains("Catch up from your DM with your parent before acting"))
      #expect(!note.contains("your box"))
      #expect(note.contains("last 2–5 messages"))
    }
  }

  @Test func restartMergesTheExecutorSpecFieldByField() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()

      let out = try await harness.call(
        "/v1/session/\(id.rawValue)/restart", .object(["effort": "low"]), as: SessionRestartOutput.self,
      )
      #expect(out.model == "test-model", "an omitted field keeps the live value")
      #expect(out.effort == "low")
      try await until("restarted onto low effort") {
        try await harness.store.record(id).executor == .kernel(.init(provider: "testing", model: "test-model", effort: "low"))
      }
    }
  }

  @Test func aCarriedMessageStartsTheFreshSessionWorking() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()

      let out = try await harness.call(
        "/v1/session/\(id.rawValue)/restart", .object(["message": "start here"]), as: SessionRestartOutput.self,
      )
      #expect(out.queued == 1)
      try await until("the fresh generation takes the opening message") {
        guard try await harness.store.generationState(id).generation == 1 else { return false }
        return try await harness.store.testLines(id).contains { $0.key.hasPrefix("message:") && $0.text.hasSuffix("\n\nstart here") }
      }
    }
  }

  @Test func restartIsRefusedWithWorkOutstandingAndOnAnUnknownSession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      try await harness.store.put(id, input: .message(.init(
        id: UUID(),
        messageID: MessageID(UUID().uuidString),
        conversationID: ConversationID("ch1"),
        sender: Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!),
        timestamp: Date(),
        content: .init(text: "hello"),
      )))
      let busy = try await harness.post("/v1/session/\(id.rawValue)/restart", .null)
      #expect(busy.status == .conflict)

      #expect(try await harness.post("/v1/session/nope/restart", .null).status == .notFound)

      let bogus = try await harness.post(
        "/v1/session/\(id.rawValue)/restart", .object(["model": "no-such-model"]),
      )
      #expect(bogus.status == .unprocessableContent)
    }
  }

  @Test func aRestartOnAnotherProviderKeepsNothingOfTheOldModel() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      _ = try await harness.space.fs(.settings).write("/models.json", Data("""
      {"testing": {"dialect": "anthropic", "baseURL": "http://localhost:1", "opaqueReplay": "affine",
        "models": {"test-model": {"maxInput": 100000, "maxOutput": 1000, "efforts": ["low", "high"], "defaultEffort": "high"}}},
       "second": {"dialect": "anthropic", "baseURL": "http://localhost:2", "opaqueReplay": "affine",
        "models": {"other-model": {"maxInput": 100000, "maxOutput": 1000, "efforts": ["low"], "defaultEffort": "low"}}}}
      """.utf8), ifMatch: nil)
      let id = try await harness.createSession()

      let modelless = try await harness.post("/v1/session/\(id.rawValue)/restart", .object(["provider": "second"]))
      #expect(modelless.status == .unprocessableContent, "another provider inherits no model")

      let switched = try await harness.call(
        "/v1/session/\(id.rawValue)/restart",
        .object(["provider": "second", "model": "other-model"]),
        as: SessionRestartOutput.self,
      )
      #expect(switched.executor == "kernel")
      #expect(switched.effort == "low", "the new model's own default, not the old effort")
      try await until("restarted onto the other provider") {
        try await harness.store.record(id).executor == .kernel(.init(provider: "second", model: "other-model", effort: "low"))
      }
    }
  }

  @Test func aBareRestartLeavesTheKernelSessionInertUnderALoopPass() async throws {
    try await withSessionDeps {
      let attempts = Mutex<[SessionID]>([])
      let harness = try await SessionHarness(inference: { request in
        attempts.withLock { $0.append(request.sessionID) }
        throw InferenceError.other(status: nil, body: "no inference expected here")
      })
      let id = try await harness.createSession()

      _ = try await harness.call("/v1/session/\(id.rawValue)/restart", .null, as: SessionRestartOutput.self)
      try await until("the loop pass to settle") {
        try await harness.store.settledWork(id)
      }

      let attempted = attempts.withLock { $0 }
      #expect(attempted.isEmpty, "a restarted session must not spend a turn on its own note")
      #expect(try await harness.store.record(id).errorMessage == nil)
      #expect(try await harness.store.settledWork(id))
    }
  }
}
