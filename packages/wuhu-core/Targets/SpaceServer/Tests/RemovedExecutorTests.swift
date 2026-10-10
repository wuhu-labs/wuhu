import Dependencies
import Fetch
import FetchSSE
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

private func legacyExecutorSession(_ harness: SessionHarness) async throws -> SessionID {
  let id = try await harness.createSession()
  let legacy = SessionExecutor.claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high"))
  try await harness.store.writer.write { db in
    try db.execute(sql: "UPDATE sessions SET executor = ?, executor_config = ? WHERE id = ?", arguments: [legacy.kind, legacy.configJSON, id.rawValue])
    try db.execute(sql: "UPDATE session_contents SET payload = ? WHERE session_id = ?", arguments: [#"{"type":"assistant","uuid":"old-turn","message":{"content":[{"type":"text","text":"old Claude Code turn"}]}}"#, id.rawValue])
  }
  return id
}

private func expectRemoved(_ response: Response) async throws {
  #expect(response.status == .unprocessableContent)
  let body = try #require(JSONValue.parse(try await response.text())?.object)
  #expect(body["code"] == "executorNoLongerSupported")
  #expect(body["message"] == "executor no longer supported")
}

@Suite(.timeLimit(.minutes(1))) struct RemovedExecutorTests {
  @Test(arguments: [0, 99]) func retiredCursorResetsAndCloses(generation: Int) async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await legacyExecutorSession(harness)
      let response = try await harness.get("/v1/session/\(id.rawValue)/direct", query: ["paged": "true", "generation": String(generation), "position": "10"])
      var events: [SessionStreamEvent] = []
      for try await frame in response.sse() { events.append(try streamEvent(frame.data)) }
      #expect(events == [.reset(generation: 0)])
    }
  }

  @Test func interruptDoesNotClearARetiredSessionsError() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await legacyExecutorSession(harness)
      try await harness.store.markErrored(id, message: "executor no longer supported")
      try await harness.runtime.service.interrupt(id)
      let record = try await harness.store.record(id)
      #expect(record.work == .errored)
      #expect(record.hold == .normal)
      #expect(record.errorMessage == "executor no longer supported")
    }
  }

  @Test func unarchivingALegacySessionReestablishesTheExecutorError() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await legacyExecutorSession(harness)
      try await harness.deliver("retained", to: id)
      try await harness.runtime.service.archive(id)
      try await harness.runtime.service.unarchive(id)
      let record = try await harness.store.record(id)
      #expect(record.lifecycle == .live)
      #expect(record.work == .errored)
      #expect(record.errorMessage == "executor no longer supported")
      #expect(try await harness.store.undrainedInputs(id).count == 1)
    }
  }

  @Test func createAndTemplateRejectRemovedExecutorWithoutCreating() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      try await expectRemoved(harness.post("/v1/session", .object([
        "title": "unsupported", "kind": "agent", "executor": "claude-code",
        "provider": "testing", "model": "test-model",
      ])))
      _ = try await harness.space.fs(.shared).write("/templates/legacy/template.json", Data("""
      {"kind":"agent", "executor":"claude-code", "provider":"testing", "model":"test-model"}
      """.utf8), ifMatch: nil)
      try await expectRemoved(harness.post("/v1/session", .object(["title": "unsupported", "template": "legacy"])))
      #expect(try await harness.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") } == 0)
    }
  }

  @Test func restartOntoRemovedExecutorIsAtomic() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      try await expectRemoved(harness.post("/v1/session/\(id.rawValue)/restart", .object(["executor": "claude-code"])))
      #expect(try await harness.store.generationState(id).generation == 0)
      #expect(try await harness.store.record(id).executor.kind == "kernel")
      await #expect(throws: ExecutorUnavailableError()) {
        try await harness.store.restart(id, executor: .claudeCode(.init(provider: "claude", model: "opus", effort: "high")))
      }
    }
  }

  @Test func bootErrorsEvenAnIdleAgentAndOnlyHandoverRecoversIt() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("handed over") }
      let id = try await legacyExecutorSession(harness)
      try await harness.running {
        try await until("expected session state") { try await harness.store.record(id).work == .errored }
        #expect(try await harness.store.record(id).errorMessage == "executor no longer supported")
        try await expectRemoved(harness.post("/v1/session/\(id.rawValue)/resume", .null))
        try await expectRemoved(harness.post("/v1/session/\(id.rawValue)/restart", .null))
        try await harness.deliver("waiting", to: id)
        #expect(try await harness.store.record(id).work == .errored)
        #expect(try await harness.store.transcriptHistory(id).entries.isEmpty)
        let restarted = try await harness.call("/v1/session/\(id.rawValue)/restart", .object([
          "provider": "testing", "model": "test-model",
        ]), as: SessionRestartOutput.self)
        #expect(restarted.executor == "kernel")
        #expect(restarted.generation == 1)
        try await until("expected session state") { try await harness.store.transcript(id).items.contains { if case .assistant = $0 { true } else { false } } }
        #expect(try await harness.store.record(id).executor.kind == "kernel")
      }
    }
  }
}
