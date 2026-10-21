import Dependencies
import DeterministicDependencies
import Fetch
import FetchSSE
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

private func retiredSession(_ harness: SessionHarness) async throws -> SessionID {
  let id = try await harness.createSession()
  let retired = SessionExecutor.retired(kind: "claude-code")
  try await harness.store.writer.write { db in
    try db.execute(sql: "UPDATE sessions SET executor = ?, executor_config = ? WHERE id = ?", arguments: [retired.kind, retired.configJSON, id.rawValue])
    try db.execute(sql: "UPDATE session_contents SET payload = ? WHERE session_id = ?", arguments: [#"{"type":"assistant","uuid":"old-turn","message":{"content":[{"type":"text","text":"old Claude Code turn"}]}}"#, id.rawValue])
  }
  return id
}

private func expectRefused(_ response: Response, status: Status, code: String, message: String) async throws {
  #expect(response.status == status)
  let body = try #require(JSONValue.parse(try await response.text())?.object)
  #expect(body["code"] == .string(code))
  #expect(body["message"] == .string(message))
}

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct RetiredExecutorTests {
  @Test(arguments: [0, 99]) func retiredCursorResetsAndCloses(generation: Int) async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await retiredSession(harness)
      let response = try await harness.get("/v1/session/\(id.rawValue)/direct", query: ["paged": "true", "generation": String(generation), "position": "10"])
      var events: [SessionStreamEvent] = []
      for try await frame in response.sse() { events.append(try streamEvent(frame.data)) }
      #expect(events == [.reset(generation: 0)])
    }
  }

  @Test func interruptDoesNotClearARetiredSessionsError() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await retiredSession(harness)
      try await harness.store.markErrored(id, message: "executor no longer supported")
      try await harness.runtime.service.interrupt(id)
      let record = try await harness.store.record(id)
      #expect(record.work == .errored)
      #expect(record.hold == .normal)
      #expect(record.errorMessage == "executor no longer supported")
    }
  }

  @Test func unarchivingARetiredSessionIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await retiredSession(harness)
      try await harness.runtime.service.archive(id)
      await #expect(throws: ExecutorUnavailableError()) {
        try await harness.runtime.service.unarchive(id)
      }
      guard case .archived = try await harness.store.record(id).lifecycle else {
        Issue.record("expected the refusal to leave the session archived")
        return
      }
    }
  }

  @Test func createAndTemplateRefuseARetiredExecutorWithoutCreating() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      try await expectRefused(harness.post("/v1/session", .object([
        "title": "unsupported", "kind": "agent", "executor": "claude-code",
        "provider": "testing", "model": "test-model",
      ])), status: .unprocessableContent, code: "invalidArgument", message: "unknown executor: claude-code")
      _ = try await harness.space.fs(.shared).write("/templates/legacy/template.json", Data("""
      {"kind":"agent", "executor":"claude-code", "provider":"testing", "model":"test-model"}
      """.utf8), ifMatch: nil)
      try await expectRefused(
        harness.post("/v1/session", .object(["title": "unsupported", "template": "legacy"])),
        status: .unprocessableContent,
        code: "invalidArgument",
        message: "template legacy: unknown executor: claude-code",
      )
      #expect(try await harness.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") } == 0)
    }
  }

  @Test func restartOntoARetiredExecutorIsAtomic() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      try await expectRefused(
        harness.post("/v1/session/\(id.rawValue)/restart", .object(["executor": "claude-code"])),
        status: .unprocessableContent,
        code: "invalidArgument",
        message: "unknown executor: claude-code",
      )
      #expect(try await harness.store.generationState(id).generation == 0)
      #expect(try await harness.store.record(id).executor.kind == "kernel")
      await #expect(throws: ExecutorUnavailableError()) {
        try await harness.store.restart(id, executor: .retired(kind: "claude-code"))
      }
    }
  }

  @Test func aLiveRetiredSessionIsNeverDrained() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("handed over") }
      let id = try await retiredSession(harness)
      try await harness.running {
        try await harness.deliver("waiting", to: id)
        try await until("the message stays queued") { try await harness.store.record(id).work == .hasWork }
        #expect(try await harness.store.transcriptSnapshot(id).items.isEmpty)
        #expect(try await harness.store.transcriptHistory(id).entries.isEmpty)
      }
    }
  }

  @Test func aLiveRetiredSessionRestartsOntoAModel() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("handed over") }
      let id = try await retiredSession(harness)
      try await harness.running {
        let restarted = try await harness.call("/v1/session/\(id.rawValue)/restart", .object([
          "provider": "testing", "model": "test-model",
        ]), as: SessionRestartOutput.self)
        #expect(restarted.executor == "kernel")
        #expect(restarted.generation == 1)
        try await harness.deliver("waiting", to: id)
        try await until("expected session state") { try await harness.store.transcript(id).items.contains { if case .assistant = $0 { true } else { false } } }
        #expect(try await harness.store.record(id).executor.kind == "kernel")
      }
    }
  }
}
