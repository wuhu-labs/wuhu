import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Synchronization
import Testing
import enum WuhuAI.InferenceError

@Suite struct SessionRestartRouteTests {
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

      let transcript = try await harness.store.transcript(id)
      #expect(transcript.items.count == 1, "the head is the whole of a restarted generation")
      guard case let .generationHead(head) = transcript.items[0] else {
        Issue.record("expected the head, got \(transcript.items[0])")
        return
      }
      let note = try #require(head.note)
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
      #expect(try await harness.store.record(id).executor == .kernel(
        .init(provider: "testing", model: "test-model", effort: "low"),
      ))
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
      let undrained = try await harness.store.hydrate(id).undrained
      #expect(undrained.count == 1)
      guard case let .message(message) = undrained[0].input else {
        Issue.record("the opening message rides the box, got \(undrained[0].input)")
        return
      }
      #expect(message.content.text == "start here")
    }
  }

  @Test func restartIsRefusedWithWorkOutstandingAndOnAnUnknownSession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      _ = try await harness.store.enqueue(id, input: .message(.init(
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
      _ = try await harness.space.fs(.shared).write("/models.json", Data("""
      {"testing": {"dialect": "anthropic", "baseURL": "http://localhost:1",
        "models": {"test-model": {"maxInput": 100000, "maxOutput": 1000, "efforts": ["low", "high"], "defaultEffort": "high"}}},
       "second": {"dialect": "anthropic", "baseURL": "http://localhost:2",
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
      #expect(try await harness.store.record(id).executor == .kernel(
        .init(provider: "second", model: "other-model", effort: "low"),
      ))
    }
  }

  @Test func aBareRestartLeavesTheKernelSessionInertUnderALoopPass() async throws {
    try await withSessionDeps {
      let attempts = Mutex<[SessionID]>([])
      let harness = try await SessionHarness(inference: { request, _ in
        attempts.withLock { $0.append(request.sessionID) }
        throw InferenceError.other(status: nil, body: "no inference expected here")
      })
      let id = try await harness.createSession()

      _ = try await harness.call("/v1/session/\(id.rawValue)/restart", .null, as: SessionRestartOutput.self)
      // The verb path materializes the session and mounts its looper, so this
      // is a real loop pass over the restarted transcript.
      try await harness.runtime.service.wake(id)
      try await until("the loop pass to settle") {
        try await harness.store.record(id).work == .noWork
      }

      let attempted = attempts.withLock { $0 }
      #expect(attempted.isEmpty, "a restarted session must not spend a turn on its own note")
      #expect(try await harness.store.record(id).errorMessage == nil)
      #expect(try await !harness.store.transcript(id).hasWork)
    }
  }
}
