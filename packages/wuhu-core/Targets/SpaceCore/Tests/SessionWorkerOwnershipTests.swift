#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
import SessionDomain
import SpaceCore
import Testing

@Suite struct SessionWorkerOwnershipTests {
  @Test func completeOwnershipSurvivesReopenAndIncludesDetachedScriptsAfterAssignmentYield() async throws {
    try await withSessionDeps {
      let scratch = try ScratchFolder("worker-ownership")
      defer { scratch.remove() }
      let file = scratch.url.appendingPathComponent("space.sqlite")
      let space = try Space.open(file: file)
      let a = try await space.sessions.createSession(group: .shared, title: "assigned", kind: .agent, createdBy: "owner", model: .test)
      let b = try await space.sessions.createSession(group: .shared, title: "script only", kind: .agent, createdBy: "owner", model: .test)
      let old = UUID(), current = UUID(), legacy = UUID()
      #expect(try await space.sessions.sessionsOwnedByWorkers([legacy]) == nil)
      try await space.sessions.beginWorkerOwnership(incarnation: old)
      try await space.sessions.beginWorkerOwnership(incarnation: current)
      try await space.sessions.assignWorker(a, incarnation: old)
      try await space.sessions.assignWorker(a, incarnation: old)
      try await space.sessions.registerWorkerScript("detached", session: b, incarnation: old)
      try await space.sessions.releaseWorkerAssignment(a, incarnation: old)
      try await space.sessions.assignWorker(a, incarnation: current)
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([old]) == [b])
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([current]) == [a])
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([old, current]) == [a, b])
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([old, legacy]) == nil)
      try await reopened.sessions.releaseWorkerScript("detached", session: b, incarnation: current)
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([old]) == [b])
      try await reopened.sessions.releaseWorkerScript("detached", session: b, incarnation: old)
      #expect(try await reopened.sessions.sessionsOwnedByWorkers([old]) == [])
    }
  }

  @Test func restartConsumesOnlySafeScriptOwnersAndDeduplicatesMachineProcesses() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let blocked = try await space.sessions.createSession(group: .shared, title: "blocked", kind: .agent, createdBy: "owner", model: .test)
      let safe = try await space.sessions.createSession(group: .shared, title: "safe", kind: .agent, createdBy: "owner", model: .test)
      let incarnation = UUID()
      try await space.sessions.beginWorkerOwnership(incarnation: incarnation)
      try await space.sessions.registerWorkerScript("pure", session: blocked, incarnation: incarnation)
      try await space.sessions.registerWorkerScript("with-exec", session: blocked, incarnation: incarnation)
      try await space.sessions.registerWorkerScript("handler-fixture", session: blocked, incarnation: incarnation)
      try await space.sessions.registerWorkerScript("safe", session: safe, incarnation: incarnation)
      let machine = try await space.addMachine(name: "fixture").id
      let exec = try await space.mintScriptExec(machine: machine, session: blocked.rawValue, script: "with-exec")
      let consumed = try await space.takeScriptExecOwners(excluding: [blocked])
      #expect(consumed.count == 1)
      #expect(consumed.first?.script == "safe")
      #expect(try await space.takeScriptExecOwners(excluding: [blocked]).isEmpty)
      #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [blocked])
      let pending = try await space.takeScriptExecOwners()
      #expect(Set(pending.map(\.script)) == ["pure", "with-exec"])
      #expect(pending.first(where: { $0.script == "with-exec" })?.live == [exec.id])
      #expect(try await space.takeScriptExecOwners().isEmpty)
    }
  }

  @Test func excludedWorkersKeepTheirActiveLeasesWithoutSuppressingOtherCrashRecovery() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let blocked = try await space.sessions.createSession(group: .shared, title: "blocked", kind: .agent, createdBy: "owner", model: .test)
      let safe = try await space.sessions.createSession(group: .shared, title: "safe", kind: .agent, createdBy: "owner", model: .test)
      let alive = UUID(), dead = UUID()
      try await space.sessions.setWorkerActivity(blocked, incarnation: alive, active: true)
      try await space.sessions.setWorkerActivity(safe, incarnation: dead, active: true)
      #expect(try await space.sessions.recordWorkerLoss(excluding: [alive]) == [safe: false])
      #expect(try await space.sessions.recordWorkerLoss(excluding: [alive]).isEmpty)
      #expect(try await space.sessions.recordWorkerLoss(incarnation: alive) == [blocked: false])
    }
  }
}
