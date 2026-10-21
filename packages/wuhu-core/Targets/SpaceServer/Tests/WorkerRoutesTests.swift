import DeterministicDependencies
import Foundation
import JSONValue
import MainHub
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing

// The loop's journal and queue as the worker reaches them: `MainClient` over
// the in-process API with the worker's token, answered by the worker routes.
@Suite(.deterministicDependencies) struct WorkerRoutesTests {
  private struct Rig {
    let harness: SessionHarness
    let tokens: ExecTokens
    let credential: WorkerCredential
    let client: MainClient
    let session: SessionID
  }

  private func rig() async throws -> Rig {
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let harness = try await SessionHarness(execTokens: tokens)
    let connection = MainConnection()
    connection.bind(harness.api)
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let session = try await harness.store.createSession(group: .shared, title: "loop", kind: .agent, createdBy: "owner", executor: model)
    let credential = harness.runtime.workers.mint()
    return Rig(harness: harness, tokens: tokens, credential: credential, client: MainClient(connection: connection, credential: { credential.token }), session: session)
  }

  private func notice(_ text: String) -> QueueInput {
    .notification(SystemNotification(
      id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: .timer, subscriptionID: SubscriptionID("timer.tc-0"), content: .init(text: text),
    ))
  }

  @Test func theJournalAndQueueAnswerTheWorker() async throws {
    try await withSessionDeps {
      let rig = try await rig()
      let (client, session) = (rig.client, rig.session)
      #expect(try await client.record(session).id == session)
      #expect(try await client.modelRoute(session) == nil)
      #expect(try await client.pendingCommand(session) == nil)
      #expect(try await client.claimCompactRequest(session, generation: 0) == nil)
      #expect(try await client.registeredSubscriptions(session).ids.isEmpty)
      #expect(try await client.owedExecs(session).isEmpty)

      let position = try await client.append(session, .inputEnqueued(notice("first"))).value(Int.self)
      #expect(try await client.queueHead(session) == position)
      let hydration = try await client.hydrate(session)
      #expect(hydration.undrained.count == 1 && hydration.generation == 0)
      let drained = try await client.drainQueue(session)
      #expect(drained.items.count == 1)

      let result = TranscriptItem.toolResult(.init(
        id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), provenance: .toolCall(.init("call_1")), payload: .failure(.init(message: "over the wire")),
      ))
      let before = try await client.hydrate(session).transcript
      let appended = SessionEvent.transcriptAppended(items: [result], inputOrigin: nil, completing: nil)
      try await client.append(session, appended).value(Void.self)
      try await client.append(session, appended).value(Void.self)
      let after = try await client.hydrate(session).transcript
      guard case let .kernel(was) = before, case let .kernel(now) = after else { Issue.record("kernel transcripts expected"); return }
      #expect(now.items == was.items + [result], "a repeated append records once")
    }
  }

  @Test func pendingArrivalsStreamToTheWorker() async throws {
    try await withSessionDeps {
      let rig = try await rig()
      _ = try await rig.client.append(rig.session, .inputEnqueued(notice("waiting")))
      var first: [PendingArrival]?
      for try await arrivals in rig.client.pendingArrivals(rig.session) {
        first = arrivals
        break
      }
      #expect(try #require(first).map(\.urgency) == [.other])
    }
  }

  // What the worker's loop asks of main beyond the journal: the session's
  // token for its tools, a park wake, and cache warming.
  @Test func theWorkerReachesTheSessionsTokenWakeAndCacheWarming() async throws {
    try await withSessionDeps {
      let rig = try await rig()
      let (client, session) = (rig.client, rig.session)
      #expect(try await client.sessionToken(session) == rig.tokens.sessionToken(session))
      try await client.scheduleWake(session, at: Date(timeIntervalSince1970: 1_800_000_000))
      try await client.scheduleWake(session, at: nil)
      #expect(try await client.allowsCacheWarming(session) == false)
      try await client.scheduleCacheWarming(session, intervalSeconds: 3300)
      await #expect(throws: MainFailure.self) { try await client.scheduleCacheWarming(session, intervalSeconds: 0) }
      let refused = try await rig.harness.post("/v1/worker/session/\(session.rawValue)/cache-warming", ["intervalSeconds": .number(1e9)], bearer: rig.credential.token)
      #expect(refused.status == .badRequest)
    }
  }

  @Test func onlyTheWorkersTokenReachesTheWorkerRoutes() async throws {
    try await withSessionDeps {
      let rig = try await rig()
      let path = "/v1/worker/session/\(rig.session.rawValue)/record"
      #expect(try await rig.harness.get(path, bearer: rig.credential.token).status == .ok)
      let session = try await rig.harness.get(path, bearer: rig.tokens.sessionToken(rig.session))
      #expect(session.status != .ok)
      let machine = try await rig.harness.space.addMachine(name: "box")
      let exec = try await rig.harness.space.mintExec(machine: machine.id, caller: rig.session.rawValue)
      let execBearer = rig.tokens.credential(session: rig.session, exec: exec.id, timeout: nil, now: Date()).token
      #expect(try await rig.harness.get(path, bearer: execBearer).status != .ok)
      #expect(try await rig.harness.get(path).status != .ok)
    }
  }
}
