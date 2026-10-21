import DeterministicDependencies
import Foundation
import MainHub
import SessionDomain
@testable import SpaceServer
import Synchronization
import Testing

// A worker as main sees it: what it was told, and which sessions it was asked
// to let go, with the policy.
private final class Line: Worker, Sendable {
  let delivered = Mutex<[(SessionID, WorkerInput)]>([])
  let revoked = Mutex<[(SessionID, RevocationPolicy)]>([])

  func deliver(_ session: SessionID, _ input: WorkerInput) async throws { delivered.withLock { $0.append((session, input)) } }
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    revoked.withLock { $0.append((session, policy)) }
    return true
  }

  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { ScriptHandlerResult(stateJSON: "null", wakes: []) }
  func activity() async -> WorkerActivity { WorkerActivity(scripts: [:]) }
  func runningWork(_ session: SessionID) async throws -> [String] { [] }
  func shutdown() async {}

  var wakes: [SessionID] { delivered.withLock { $0.compactMap { session, input in if case .wake = input { session } else { nil } } } }
}

@Suite(.deterministicDependencies) struct WorkerRegistryTests {
  private let tokens = ExecTokens(spaceURL: "http://main")
  private let s1 = SessionID("s1"), s2 = SessionID("s2"), s3 = SessionID("s3")

  private func announced(_ registry: WorkerRegistry, _ line: Line) -> WorkerCredential {
    let credential = registry.mint()
    registry.announce(credential.id, endpoint: line)
    return credential
  }

  @Test func aSessionGoesToTheLeastLoadedWorkerOnFirstContactAndStaysThere() async throws {
    let registry = WorkerRegistry(tokens: tokens)
    let a = Line(), b = Line()
    let first = announced(registry, a), second = announced(registry, b)
    try await registry.deliver(s1, .wake)
    try await registry.deliver(s2, .wake)
    try await registry.deliver(s3, .wake)
    try await registry.deliver(s1, .interrupt)
    #expect(registry.worker(of: s1) == first.id && registry.worker(of: s2) == second.id && registry.worker(of: s3) == first.id)
    #expect(a.delivered.withLock { $0.map(\.0) } == [s1, s3, s1])
    #expect(b.wakes == [s2])
    _ = try await registry.fire(.init(id: UUID(), path: "/h.js", session: s2, input: .timer(Date()), stateJSON: nil))
    #expect(tokens.worker(ofBearer: first.token) == first.id && tokens.worker(ofBearer: second.token) == second.id)
  }

  @Test func aWorkerAnnouncedAgainKeepsItsSessionsOnItsNewLine() async throws {
    let registry = WorkerRegistry(tokens: tokens)
    let old = Line(), new = Line()
    let credential = announced(registry, old)
    try await registry.deliver(s1, .wake)
    registry.announce(credential.id, endpoint: new, holding: [s2])
    try await registry.deliver(s1, .wake)
    try await registry.deliver(s2, .wake)
    #expect(old.wakes == [s1] && new.wakes == [s1, s2])
    #expect(registry.workers == [credential.id])
  }

  @Test func anArchivedSessionLeavesItsWorkerAndNoWorkerRefusesAVerb() async throws {
    let registry = WorkerRegistry(tokens: tokens)
    await #expect(throws: NoWorkerError.self) { try await registry.deliver(s1, .wake) }
    let line = Line()
    _ = announced(registry, line)
    try await registry.deliver(s1, .wake)
    try await registry.deliver(s1, .archived)
    #expect(registry.worker(of: s1) == nil)
  }

  @Test func drainHandsEachSessionOffOnceAndEndsTheWorkersToken() async throws {
    try await withSessionDeps {
      let registry = WorkerRegistry(tokens: tokens)
      let a = Line(), b = Line()
      let first = announced(registry, a), second = announced(registry, b)
      try await registry.deliver(s1, .wake)
      try await registry.deliver(s2, .wake)
      try await registry.deliver(s3, .wake)
      try await registry.drain(first.id)
      #expect(a.revoked.withLock { $0.map(\.0) } == [s1, s3])
      #expect(a.revoked.withLock { $0.allSatisfy { if case .handOff = $0.1 { true } else { false } } })
      #expect(b.wakes == [s2, s1, s3])
      #expect(registry.worker(of: s1) == second.id && registry.worker(of: s3) == second.id)
      #expect(registry.workers == [second.id])
      #expect(tokens.worker(ofBearer: first.token) == nil)
      await #expect(throws: UnknownWorkerError.self) { try await registry.drain(first.id) }
    }
  }

  @Test func drainWithNoOtherWorkerLeavesTheSessionsForTheNextAnnounce() async throws {
    try await withSessionDeps {
      let registry = WorkerRegistry(tokens: tokens)
      let a = Line(), b = Line()
      let first = announced(registry, a)
      try await registry.deliver(s1, .wake)
      try await registry.drain(first.id)
      #expect(registry.worker(of: s1) == nil && registry.workers.isEmpty)
      _ = announced(registry, b)
      try await registry.deliver(s1, .wake)
      #expect(b.wakes == [s1])
    }
  }

  // Main reboots in place: the main it becomes knows the workers the one
  // before minted, by their tokens, and mints after them.
  @Test func aMainTakingOverKnowsTheWorkersOfTheOneBefore() async throws {
    let before = WorkerRegistry(tokens: tokens)
    let a = Line()
    let first = announced(before, a)
    try await before.deliver(s1, .wake)
    let session = tokens.sessionToken(s1)
    before.detach()
    #expect(before.workers.isEmpty && before.worker(of: s1) == nil)

    let after = ExecTokens(spaceURL: "http://main")
    after.restore(tokens.table()) { _ in { true } }
    let registry = WorkerRegistry(tokens: after)
    registry.restore(mintedCount: before.mintedCount)
    #expect(after.worker(ofBearer: first.token) == first.id && after.session(ofBearer: session) == s1)
    let b = Line()
    registry.announce(first.id, endpoint: b, holding: [s1])
    try await registry.deliver(s1, .wake)
    #expect(b.wakes == [s1])
    #expect(registry.mint().id != first.id)
  }

  @Test func aWorkerGoneUnaskedLeavesItsSessionsToTheNextVerb() async throws {
    let registry = WorkerRegistry(tokens: tokens)
    let a = Line(), b = Line()
    let first = announced(registry, a)
    try await registry.deliver(s1, .wake)
    _ = announced(registry, b)
    #expect(registry.drop(first.id) == [s1])
    #expect(tokens.worker(ofBearer: first.token) == nil && registry.worker(of: s1) == nil)
    try await registry.deliver(s1, .wake)
    #expect(b.wakes == [s1])
  }

  @Test func waitingForAWorkerEndsWhenItAnnouncesOrTheWaitIsCancelled() async throws {
    let registry = WorkerRegistry(tokens: tokens)
    let credential = registry.mint()
    let waiting = Task { await registry.announcement(of: credential.id) }
    registry.announce(credential.id, endpoint: Line())
    await waiting.value
    let never = registry.mint()
    let abandoned = Task { await registry.announcement(of: never.id) }
    abandoned.cancel()
    await abandoned.value
  }
}
