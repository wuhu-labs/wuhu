import Dependencies
import DeterministicDependencies
import ExecutionOwner
import MainHub
import protocol MainHub.Main
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import Testing

private struct OwnerContract {
  let makeOwner: @Sendable (Space) -> any Main
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  func fixture() async throws -> (Space, any Main, SessionID) {
    let space = try withDependencies { $0.date = .constant(now) } operation: { try Space.inMemory() }
    let id = try await space.sessions.createSession(
      group: .shared, title: "owner contract", kind: .agent, createdBy: "owner",
      model: .init(provider: "test", model: "test", effort: "high"),
    )
    return (space, makeOwner(space), id)
  }

  func queueAndCompaction() async throws {
    let (space, owner, id) = try await fixture()
    let initial = try await owner.hydrate(id)
    #expect(initial.record == (try await owner.record(id)))
    #expect(initial.queueHead == 0)
    let input = QueueInput.notification(.init(
      id: UUID(), timestamp: now, kind: .timer,
      subscriptionID: .init("timer"), content: .init(text: "wake"),
    ))
    #expect(try await owner.append(id, .inputEnqueued(input)).value(Int.self) == 1)
    #expect(try await owner.queueHead(id) == 1)
    let drain = try await owner.drainQueue(id)
    #expect(drain.items == [input.transcriptItem])
    #expect(drain.queueTail == 1)
    #expect(try await owner.drainQueue(id).items.isEmpty)
    let missing = SessionID("missing")
    await #expect(throws: SessionStoreError.unknownSession(missing.rawValue)) {
      _ = try await owner.append(missing, .inputEnqueued(input)).value(Int.self)
    }
    guard case var .kernel(transcript) = try await owner.hydrate(id).transcript else {
      Issue.record("kernel session must hydrate a kernel transcript")
      return
    }
    let marker = TranscriptItem.bookmark(.init(id: UUID(), timestamp: now, name: "boundary"))
    transcript.append(marker)
    try await owner.append(id, .transcriptAppended(items: [marker], inputOrigin: transcript.cacheWarmingInputOrigin, completing: nil)).value(Void.self)
    #expect(try await owner.hydrate(id).transcript == .kernel(transcript))
    try await space.sessions.requestCommand(id, .compact(instructions: "keep the boundary"))
    #expect(try await owner.pendingCommand(id) == .compact(instructions: "keep the boundary"))
    let claim = try #require(try await owner.claimCompactRequest(id, generation: 0))
    #expect(try await owner.claimCompactRequest(id, generation: 0) == claim)
    let head = GenerationHead(id: UUID(), timestamp: now, summary: "compacted", snapshot: .init(), settle: .init(), runningWork: [])
    let compacted = try await owner.append(id, .compacted(closing: nil, head: head, kept: nil, completing: claim, transition: nil)).value(Transcript.self)
    #expect(try await owner.pendingCommand(id) == nil)
    #expect(try await owner.hydrate(id).generation == 1)
    #expect(try await owner.hydrate(id).transcript == .kernel(compacted))
    let registered = try await owner.registeredSubscriptions(id)
    #expect(registered.ids.isEmpty)
    #expect(registered.handlers.isEmpty)
  }

  func lifecycleAndErrors() async throws {
    let (space, owner, id) = try await fixture()
    try await owner.append(id, .interrupted).value(Void.self)
    #expect(try await owner.record(id).hold == .interrupted)
    try await owner.append(id, .resumed).value(Void.self)
    #expect(try await owner.record(id).hold == .normal)
    try await owner.append(id, .errored("contract failure")).value(Void.self)
    #expect(try await owner.record(id).errorMessage == "contract failure")
    let expiry = try await space.sessions.archive(id, grace: .seconds(60))
    #expect(try await owner.record(id).lifecycle == .archived(graceExpiresAt: expiry))
    try await space.sessions.unarchive(id)
    #expect(try await owner.record(id).lifecycle == .live)
    let restart = try await space.sessions.restart(id, note: "new start")
    #expect(try await owner.hydrate(id).generation == restart.generation)
    let missing = SessionID("missing")
    await #expect(throws: SessionStoreError.unknownSession(missing.rawValue)) {
      _ = try await owner.hydrate(missing)
    }
  }
}

@Suite(.deterministicDependencies) struct HubOwnerContractTests {
  private let contract = OwnerContract { Hub(space: $0) }

  @Test func queueAndCompaction() async throws { try await contract.queueAndCompaction() }
  @Test func lifecycleAndErrors() async throws { try await contract.lifecycleAndErrors() }
}

extension HubOwnerContractTests {
  @Test func groupDeclarationsAndPreparedRoutesAreOwnerEffects() async throws {
    let space = try Space.inMemory()
    let owner = Hub(space: space)
    let spec = ModelSpecifier(provider: "test", model: "test", effort: "high")
    let first = SessionModelRoute(group: "work", member: "a", specifier: spec, bindingFingerprint: "fixture", epoch: "first", reason: .create, placedAt: Date(), evidence: [])
    let id = try await space.sessions.createSession(group: .shared, title: "group", kind: .agent, createdBy: "owner", executor: .modelGroup(id: "work", effort: "high"), modelRoute: first)
    #expect(try await owner.modelRoute(id) == first)
    var next = first
    next.member = "b"
    next.epoch = "next"
    next.reason = .startOver
    _ = try await space.sessions.restart(id, executor: .modelGroup(id: "work", effort: "high"), modelRoute: next)
    #expect(try await owner.modelRoute(id) == next)
    #expect(try await space.sessions.modelRouteHistory(id) == [first, next])
  }
}

extension HubOwnerContractTests {
  @Test func restartAnnouncesEachScriptOwnerOnlyOnce() async throws {
    let (space, _, session) = try await contract.fixture()
    let owner = Hub(space: space)
    let machine = try await space.addMachine(name: "box").id
    let running = try await space.mintScriptExec(machine: machine, caller: session.rawValue, script: "running")
    let finished = try await space.mintScriptExec(machine: machine, caller: session.rawValue, script: "running")
    try await space.finishExec(finished.id, .exited(code: 0))
    let other = try await space.mintScriptExec(machine: machine, caller: session.rawValue, script: "finished")
    try await space.finishExec(other.id, .exited(code: 0))
    await owner.announceScriptRestart()
    let queued = try await owner.hydrate(session).undrained.map(\.input)
    #expect(queued.count == 2)
    let notices = queued.compactMap { input -> SystemNotification? in
      if case let .notification(value) = input { return value }; return nil
    }
    #expect(Set(notices.map(\.subscriptionID)) == [.script("running"), .script("finished")])
    #expect(notices.allSatisfy { $0.kind == .script && $0.content.text.contains("was killed by a server restart") })
    #expect(notices.first { $0.subscriptionID == .script("running") }?.content.text.contains(running.id.rawValue) == true)
    await owner.announceScriptRestart()
    #expect(try await owner.queueHead(session) == 2)
    #expect(try await owner.drainQueue(session).items == queued.map(\.transcriptItem))
    #expect(try await space.takeScriptExecOwners().isEmpty)
  }
}
