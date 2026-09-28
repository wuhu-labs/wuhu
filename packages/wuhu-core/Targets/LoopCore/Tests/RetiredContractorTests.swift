import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

// A session left from the removed contractor executor: the service never
// materializes it, every verb acts on the store, and a restart onto a model
// is the way back.
@Suite struct RetiredContractorTests {
  @Test func bootAndWakeNeverMaterializeALeftoverContractorSession() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(
        group: .shared,
        title: "c", kind: .agent, createdBy: "morgan", executor: .contractor(name: "retired"),
      )
      _ = try await sessions.enqueue(sid, input: Fix.message("pre-boot backlog"))
      #expect(try await sessions.bootSessions().isEmpty)

      let script = InferenceScript([])
      let config = makeConfig(inference: { try await script($0) })
      try await runService(sessions, config) { service in
        let queued = try await service.enqueue(item: Fix.message("post-boot work", message: "m2"), to: sid)
        #expect(queued == 2)
        try await service.wake(sid)
        try await holds("the leftover session is untouched by the kernel loop") {
          let hydration = try await sessions.hydrate(sid)
          return hydration.queueTail == 0 && script.count == 0
        }
      }
    }
  }

  @Test func theVerbsActOnTheStoreAndARestartOntoAModelIsTheWayBack() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(
        group: .shared,
        title: "c", kind: .agent, createdBy: "morgan", executor: .contractor(name: "retired"),
      )
      try await runService(sessions, makeConfig()) { service in
        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)
        try await service.resume(sid)
        #expect(try await sessions.record(sid).hold == .normal)

        try await service.archive(sid)
        guard case .archived = try await sessions.record(sid).lifecycle else {
          Issue.record("expected archived lifecycle")
          return
        }
        try await service.unarchive(sid)
        #expect(try await sessions.record(sid).lifecycle == .live)

        let restart = try await service.restart(sid, executor: .kernel(.test), note: nil)
        #expect(restart.executor == .kernel(.test))
        #expect(restart.generation == 1)
        #expect(try await sessions.record(sid).executor == .kernel(.test))
      }
    }
  }
}
