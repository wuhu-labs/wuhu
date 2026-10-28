import DeterministicDependencies
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// The routes the worker reads its inference inputs through and reports to.
// They answer the worker's own token; an exec's token, which any command in
// the exec can print, is refused.
private func worker(_ harness: SessionHarness, _ tokens: ExecTokens) async throws -> (SessionID, String) {
  let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
  let session = try await harness.store.createSession(group: .shared, title: "worker", kind: .agent, createdBy: "owner", executor: model)
  return (session, tokens.sessionToken(session))
}

private func execBearer(_ harness: SessionHarness, _ tokens: ExecTokens, session: SessionID) async throws -> String {
  let machine = (try await harness.space.addMachineV2(name: "box")).machine
  let exec = try await harness.space.mintExec(machine: machine.id, caller: session.rawValue)
  return tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
}

@Suite(.deterministicDependencies) struct InferenceRouteTests {
  @Test func promptIsRenderedOnceAtTheSessionsPromptRevision() async throws {
    try await withSessionDeps {
      let tokens = ExecTokens(spaceURL: "https://space.test:5530")
      let harness = try await SessionHarness(execTokens: tokens)
      let fs = await harness.space.fs(.shared)
      let guidance = try await fs.write("/AGENTS.md", Data("frozen guidance".utf8), ifMatch: nil)
      let (session, token) = try await worker(harness, tokens)
      let first = try await harness.get("/v1/prompt", bearer: token)
      #expect(first.status == .ok)
      let prompt = try JSONDecoder().decode(SessionPromptOutput.self, from: try await first.body.data())
      #expect(prompt.session == PromptSession(
        id: session.rawValue, title: "worker", kind: .agent, model: "testing/test-model", tags: [], home: "/_/sessions/\(session.rawValue)",
      ))
      #expect(prompt.prompt.contains("from /AGENTS.md:\n\nfrozen guidance"), "\(prompt.prompt)")
      _ = try await fs.write("/AGENTS.md", Data("later edit".utf8), ifMatch: guidance)
      _ = try await harness.store.setTitle(session, to: "renamed")
      let second = try await harness.get("/v1/prompt", bearer: token)
      #expect(try JSONDecoder().decode(SessionPromptOutput.self, from: try await second.body.data()) == prompt)
    }
  }

  @Test func mediaIsWorkerOnlyWithoutBlobOwnershipOrFileReaderChecks() async throws {
    try await withSessionDeps {
      let tokens = ExecTokens(spaceURL: "https://space.test:5530")
      let harness = try await SessionHarness(execTokens: tokens)
      let (session, token) = try await worker(harness, tokens)
      let (_, otherToken) = try await worker(harness, tokens)
      let bytes = Data([1, 2, 3, 4])
      let hash = try await harness.space.storeImage(bytes)
      let found = try await harness.get("/v1/media", query: ["url": "wuhu-blob:\(hash)"], bearer: token)
      #expect(found.status == .ok)
      #expect(try await found.body.data() == bytes)
      let foreign = try await harness.get("/v1/media", query: ["url": "wuhu-blob:\(hash)"], bearer: otherToken)
      #expect(foreign.status == .ok)
      let missing = try await harness.get("/v1/media", query: ["url": "wuhu-blob:\(String(repeating: "0", count: 64))"], bearer: token)
      #expect(missing.status == .notFound)
      let execToken = try await execBearer(harness, tokens, session: session)
      let exec = try await harness.get("/v1/media", query: ["url": "wuhu-blob:\(hash)"], bearer: execToken)
      #expect(exec.status == .forbidden)
      let account = try await harness.space.addAccount(kind: .human, name: "attachment owner")
      let group = try #require(try await harness.space.personalGroup(of: account.id))
      _ = try await harness.space.fs(group).write("/attachment.png", bytes, ifMatch: nil)
      let reference = "wuhu-space:wuhu://\(group.rawValue).localspace/attachment.png"
      let attachment = try await harness.get("/v1/media", query: ["url": reference], bearer: token)
      #expect(attachment.status == .ok)
      #expect(try await attachment.body.data() == bytes)
      let refused = try await harness.get("/v1/media", query: ["url": reference], bearer: execToken)
      #expect(refused.status == .forbidden)
      let malformed = try await harness.get("/v1/media", query: ["url": "https://example.com/image.png"], bearer: token)
      #expect(malformed.status == .badRequest)
    }
  }

  @Test func reportedInferencesCarryThePrincipal() async throws {
    try await withSessionDeps {
      let recorded = Mutex<[InferenceMetric]>([])
      let tokens = ExecTokens(spaceURL: "https://space.test:5530")
      let harness = try await SessionHarness(execTokens: tokens, metrics: .init { metric in recorded.withLock { $0.append(metric) } })
      let (session, token) = try await worker(harness, tokens)
      let response = try await harness.post("/v1/inferences", .object([
        "id": .string("attempt-1"), "timestamp": .number(1_700_000_000), "provider": .string("offline"), "model": .string("small"), "servedModel": .string("served-small"),
        "effort": .string("low"), "outcome": .string("ok"), "durationMs": .integer(123), "ttftMs": .integer(45),
        "usage": .object(["inputTokens": .integer(10), "outputTokens": .integer(5), "cacheReadTokens": .integer(4), "cacheWriteTokens": .integer(2), "totalTokens": .integer(21)]),
      ]), bearer: token)
      #expect(response.status == .ok)
      let metric = try #require(recorded.withLock { $0.first })
      #expect(metric.id == "attempt-1" && metric.session == session)
      #expect(metric.provider == "offline" && metric.model == "small" && metric.servedModel == "served-small")
      #expect(metric.outcome == .ok && metric.durationMs == 123 && metric.ttftMs == 45)
      #expect(metric.usage?.inputTokens == 10 && metric.usage?.cacheReadTokens == 4)
      let unknown = try await harness.post("/v1/inferences", .object([
        "id": .string("attempt-2"), "timestamp": .number(1_700_000_000), "provider": .string("offline"), "model": .string("small"),
        "effort": .string("low"), "outcome": .string("sideways"), "durationMs": .integer(1),
      ]), bearer: token)
      #expect(unknown.status == .badRequest)
      let negative = try await harness.post("/v1/inferences", .object([
        "id": .string("attempt-3"), "timestamp": .number(1_700_000_000), "provider": .string("offline"), "model": .string("small"),
        "effort": .string("low"), "outcome": .string("ok"), "durationMs": .integer(-1),
      ]), bearer: token)
      #expect(negative.status == .badRequest)
      let exec = try await harness.post("/v1/inferences", .object([
        "id": .string("attempt-4"), "timestamp": .number(1_700_000_000), "provider": .string("offline"), "model": .string("small"),
        "effort": .string("low"), "outcome": .string("ok"), "durationMs": .integer(1),
      ]), bearer: try await execBearer(harness, tokens, session: session))
      #expect(exec.status == .forbidden)
      #expect(recorded.withLock { $0.count } == 1)
    }
  }

  // The worker retries a report it cannot prove reached the server; the
  // attempt id makes the second arrival record nothing.
  @Test func anInferenceIsRecordedOncePerAttempt() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(
        group: .shared, title: "worker", kind: .agent, createdBy: "fixture", model: .init(provider: "offline", model: "small", effort: "low"),
      )
      let metric = InferenceMetric(
        id: "attempt-1", timestamp: Date(timeIntervalSince1970: 1_700_000_000), payer: .session(session), provider: "offline", model: "small",
        effort: "low", outcome: .ok, durationMs: 123,
      )
      try await space.recordInference(InferenceRecord(metric))
      try await space.recordInference(InferenceRecord(metric))
      #expect(try await space.query("SELECT id FROM inferences", as: .shared(.anonymous)).rows == [[.text("attempt-1")]])
    }
  }
}
