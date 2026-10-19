import Credentials
import Dependencies
import ExecutionOwner
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import Scratch
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

private struct OwnerContract {
  let makeOwner: @Sendable (Space, InferenceMetricsSink) -> any ExecutionOwnerClient
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  func fixture() async throws -> (Space, any ExecutionOwnerClient, SessionID) {
    let space = try withDependencies { $0.date = .constant(now) } operation: { try Space.inMemory() }
    let id = try await space.sessions.createSession(
      group: .shared, title: "owner contract", kind: .agent, createdBy: "owner",
      model: .init(provider: "test", model: "test", effort: "high"),
    )
    return (space, makeOwner(space, .noop), id)
  }

  func queueAndCompaction() async throws {
    let (space, owner, id) = try await fixture()
    let initial = try await owner.send(.read(id, .hydration)).value(SessionHydration.self)
    #expect(initial.record == (try await owner.send(.read(id, .record)).value(SessionRecord.self)))
    #expect(initial.queueHead == 0)
    let input = QueueInput.notification(.init(
      id: UUID(), timestamp: now, kind: .timer,
      subscriptionID: .init("timer"), content: .init(text: "wake"),
    ))
    #expect(try await owner.send(.append(id, .inputEnqueued(input))).value(Int.self) == 1)
    #expect(try await owner.send(.read(id, .queueHead)).value(Int.self) == 1)
    let drain = try await owner.send(.effect(id, .drainQueue)).value(QueueDrain.self)
    #expect(drain.items == [input.transcriptItem])
    #expect(drain.queueTail == 1)
    #expect(try await owner.send(.effect(id, .drainQueue)).value(QueueDrain.self).items.isEmpty)
    guard case var .kernel(transcript) = try await owner.send(.read(id, .hydration)).value(SessionHydration.self).transcript else {
      Issue.record("kernel session must hydrate a kernel transcript")
      return
    }
    let marker = TranscriptItem.bookmark(.init(id: UUID(), timestamp: now, name: "boundary"))
    transcript.append(marker)
    try await owner.send(.append(id, .transcriptAppended(items: [marker], transcript: transcript, completing: nil))).value(Void.self)
    #expect(try await owner.send(.read(id, .hydration)).value(SessionHydration.self).transcript == .kernel(transcript))
    try await space.sessions.requestCommand(id, .compact(instructions: "keep the boundary"))
    #expect(try await owner.send(.read(id, .pendingCommand)).value(SessionCommand?.self) == .compact(instructions: "keep the boundary"))
    let claim = try #require(try await owner.send(.effect(id, .claimCompactRequest(generation: 0))).value(CompactRequestClaim?.self))
    #expect(try await owner.send(.effect(id, .claimCompactRequest(generation: 0))).value(CompactRequestClaim?.self) == claim)
    let head = GenerationHead(id: UUID(), timestamp: now, summary: "compacted", snapshot: .init(), settle: .init(), runningWork: [])
    let compacted = try await owner.send(.append(id, .compacted(closing: nil, head: head, kept: nil, completing: claim, transition: nil))).value(Transcript.self)
    #expect(try await owner.send(.read(id, .pendingCommand)).value(SessionCommand?.self) == nil)
    #expect(try await owner.send(.read(id, .hydration)).value(SessionHydration.self).generation == 1)
    #expect(try await owner.send(.read(id, .hydration)).value(SessionHydration.self).transcript == .kernel(compacted))
    #expect(try await owner.send(.read(id, .scopeContext(.init("unknown")))).value(ScopeContext?.self) == nil)
    let registered = try await owner.send(.read(id, .registeredSubscriptions)).value(RegisteredSubscriptions.self)
    #expect(registered.ids.isEmpty)
    #expect(registered.handlers.isEmpty)
  }

  func lifecycleAndErrors() async throws {
    let (_, owner, id) = try await fixture()
    try await owner.send(.append(id, .interrupted)).value(Void.self)
    #expect(try await owner.send(.read(id, .record)).value(SessionRecord.self).hold == .interrupted)
    try await owner.send(.append(id, .resumed)).value(Void.self)
    #expect(try await owner.send(.read(id, .record)).value(SessionRecord.self).hold == .normal)
    try await owner.send(.append(id, .errored("contract failure"))).value(Void.self)
    #expect(try await owner.send(.read(id, .record)).value(SessionRecord.self).errorMessage == "contract failure")
    let expiry = try await owner.send(.append(id, .archived(grace: .seconds(60)))).value(Date.self)
    #expect(try await owner.send(.read(id, .record)).value(SessionRecord.self).lifecycle == .archived(graceExpiresAt: expiry))
    try await owner.send(.append(id, .unarchived)).value(Void.self)
    #expect(try await owner.send(.read(id, .record)).value(SessionRecord.self).lifecycle == .live)
    let restart = try await owner.send(.append(id, .restarted(executor: nil, note: "new start", modelRoute: nil))).value(SessionRestart.self)
    #expect(try await owner.send(.read(id, .hydration)).value(SessionHydration.self).generation == restart.generation)
    let missing = SessionID("missing")
    await #expect(throws: SessionStoreError.unknownSession(missing.rawValue)) {
      _ = try await owner.send(.read(missing, .hydration)).value(SessionHydration.self)
    }
  }

  func inferenceInputs() async throws {
    let (space, owner, id) = try await fixture()
    let data = Data("models are live".utf8)
    _ = try await space.fs(.shared).write("/models.json", data, ifMatch: nil)
    #expect(try await owner.modelDocument() == data)
    let guidanceToken = try await space.fs(.shared).write("/AGENTS.md", Data("frozen owner guidance".utf8), ifMatch: nil)
    let home = try await owner.promptHome(id)
    _ = try await space.fs(.shared).write("/AGENTS.md", Data("later edit".utf8), ifMatch: guidanceToken)
    #expect(try await owner.promptHome(id) == home)
    let bytes = Data([1, 2, 3, 4])
    let hash = try await space.storeImage(bytes)
    #expect(try await owner.mediaBytes(.blob(hash), group: .shared) == bytes)
    _ = try await space.fs(.shared).write("/media.bin", bytes, ifMatch: nil)
    #expect(try await owner.mediaBytes(.spaceFile("/media.bin"), group: .shared) == bytes)
    await #expect(throws: (any Error).self) {
      _ = try await owner.mediaBytes(.spaceFile("/missing.bin"), group: .shared)
    }
  }

  func metrics() async throws {
    let recorded = RecordedMetrics()
    let space = try withDependencies { $0.date = .constant(now) } operation: { try Space.inMemory() }
    let owner = makeOwner(space, .init { await recorded.append($0) })
    let metric = InferenceMetric(
      timestamp: now, session: .init("session"), provider: "provider", model: "model",
      effort: "high", outcome: .timeout, errorKind: "idleTimeout", durationMs: 123,
    )
    await owner.recordMetric(metric)
    #expect(await recorded.values == [metric])
  }
}

private actor RecordedMetrics {
  var values: [InferenceMetric] = []
  func append(_ metric: InferenceMetric) { values.append(metric) }
}

@Suite struct InProcessOwnerContractTests {
  private let contract = OwnerContract { InProcessExecutionOwnerClient(space: $0, metrics: $1) }

  @Test func queueAndCompaction() async throws { try await contract.queueAndCompaction() }
  @Test func lifecycleAndErrors() async throws { try await contract.lifecycleAndErrors() }
  @Test func inferenceInputs() async throws { try await contract.inferenceInputs() }
  @Test func metrics() async throws { try await contract.metrics() }

  @Test func tracesAreOwnerEffects() async throws {
    let folder = try ScratchFolder("owner-traces")
    defer { folder.remove() }
    let config = AttemptLogConfig(directory: folder.url.appendingPathComponent("traces"))
    let owner = InProcessExecutionOwnerClient(space: try Space.inMemory(), attemptLog: config)
    #expect(owner.tracesAttempts)
    #expect(!InProcessExecutionOwnerClient(space: try Space.inMemory()).tracesAttempts)
    try await assertTraceContract(owner: owner) { id in
      try Data(contentsOf: config.directory.appendingPathComponent("\(id.uuidString.lowercased()).log"))
    }
  }

  @Test func credentialsAndSigningAreOwnerEffects() async throws {
    let space = try Space.inMemory()
    let owner = InProcessExecutionOwnerClient(
      space: space,
      credentials: .init { $0 == "test" ? .apiKey("fixture-key") : nil },
      inferenceToken: { audience, session in "\(audience.host!):\(session.rawValue)" },
    )
    #expect(try await owner.providerCredential("test") == .apiKey("fixture-key"))
    #expect(try await owner.providerCredential("unknown") == nil)
    #expect(try await owner.inferenceToken(audience: URL(string: "https://provider.example")!, session: .init("session")) == "provider.example:session")
    let unavailable = InProcessExecutionOwnerClient(space: space)
    do {
      _ = try await unavailable.inferenceToken(audience: URL(string: "https://provider.example")!, session: .init("session"))
      Issue.record("unconfigured signing must fail")
    } catch let InferenceError.invalidInput(status, body) {
      #expect(status == 422)
      #expect(body == "OIDC authentication is not configured on this server.")
    }
  }
}

private func assertTraceContract(
  owner: any ExecutionOwnerClient,
  read: @Sendable (UUID) throws -> Data,
) async throws {
  let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let trace = try await owner.openAttemptTrace(id)
  await trace.append(Data("request\n\n".utf8))
  await trace.append(Data("partial".utf8))
  #expect(try read(id) == Data("request\n\npartial".utf8))
  let independent = try await owner.openAttemptTrace(other)
  await independent.append(Data("other".utf8))
  #expect(try read(other) == Data("other".utf8))
  let retry = try await owner.openAttemptTrace(id)
  await retry.append(Data("retry".utf8))
  #expect(try read(id) == Data("retry".utf8))
  #expect(try read(other) == Data("other".utf8))
}

extension InProcessOwnerContractTests {
  @Test func groupDeclarationsAndPreparedRoutesAreOwnerEffects() async throws {
    let space = try Space.inMemory()
    let owner = InProcessExecutionOwnerClient(space: space)
    #expect(try await owner.modelGroupDocument() == nil)
    let data = Data("{}".utf8)
    _ = try await space.fs(.shared).write("/model-groups.json", data, ifMatch: nil)
    #expect(try await owner.modelGroupDocument() == data)
    let spec = ModelSpecifier(provider: "test", model: "test", effort: "high")
    let first = SessionModelRoute(group: "work", member: "a", specifier: spec, bindingFingerprint: "fixture", epoch: "first", reason: .create, placedAt: Date(), evidence: [])
    let id = try await space.sessions.createSession(group: .shared, title: "group", kind: .agent, createdBy: "owner", executor: .modelGroup(id: "work", effort: "high"), modelRoute: first)
    #expect(try await owner.send(.read(id, .modelRoute)).value(SessionModelRoute?.self) == first)
    var next = first
    next.member = "b"
    next.epoch = "next"
    next.reason = .startOver
    _ = try await owner.send(.append(id, .restarted(executor: .modelGroup(id: "work", effort: "high"), note: nil, modelRoute: next))).value(SessionRestart.self)
    #expect(try await owner.send(.read(id, .modelRoute)).value(SessionModelRoute?.self) == next)
    #expect(try await space.sessions.modelRouteHistory(id) == [first, next])
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")) {
      try await owner.inferenceReadiness(audience: URL(string: "https://provider.example")!)
    }
  }
}
