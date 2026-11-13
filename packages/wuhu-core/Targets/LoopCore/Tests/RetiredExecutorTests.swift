import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

// A session left from an executor this build no longer has: the service never
// materializes it, the verbs read the store, and a restart onto a model is the
// way back.
@Suite struct RetiredExecutorTests {
  @Test func undrainedRetiredInputDoesNotRequireForceToArchive() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let service = SessionExecution(space: space, loopConfig: makeConfig())
      let sid = try await createRetiredSession(in: space, title: "retired", createdBy: "owner")
      try await sessions.enqueue(sid, input: Fix.message("queued"))
      try await runService(service) { service in
        try await service.archive(sid)
        try await until("archived") { try await sessions.record(sid).lifecycle != .live }
        #expect(try await sessions.record(sid).hold == .normal)
        #expect(try await sessions.hydrate(sid).queueTail == 0)
      }
    }
  }

  @Test func bootAndWakeNeverMaterializeALeftoverRetiredSession() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([])
      let config = makeConfig(inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let sid = try await createRetiredSession(in: space, title: "c", createdBy: "morgan")
      try await sessions.enqueue(sid, input: Fix.message("pre-boot backlog"))
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("post-boot work", message: "m2"), to: sid)
        try await sessions.look(sid)
        try await holds("the leftover session is untouched by the kernel loop") {
          let hydration = try await sessions.hydrate(sid)
          return hydration.queueTail == 0 && script.count == 0
        }
      }
    }
  }

  @Test func theVerbsRefuseWhatWouldRunItAndARestartOntoAModelIsTheWayBack() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let service = SessionExecution(space: space, loopConfig: makeConfig())
      let sid = try await createRetiredSession(in: space, title: "c", createdBy: "morgan")
      try await runService(service) { service in
        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .normal)
        await #expect(throws: ExecutorUnavailableError()) { try await service.resume(sid) }

        let restart = try await service.restart(sid, executor: .kernel(.test), note: nil)
        #expect(restart.executor == .kernel(.test))
        #expect(restart.generation == 1)
        try await until("restarted onto the model") { try await sessions.record(sid).executor == .kernel(.test) }
      }
    }
  }

  @Test func anArchivedRetiredSessionIsNeverUnarchived() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let service = SessionExecution(space: space, loopConfig: makeConfig())
      let sid = try await createRetiredSession(in: space, title: "c", createdBy: "morgan")
      try await runService(service) { service in
        try await service.archive(sid)
        try await until("archived") { try await sessions.record(sid).lifecycle != .live }
        await #expect(throws: ExecutorUnavailableError()) { try await service.unarchive(sid) }
        guard case .archived = try await sessions.record(sid).lifecycle else {
          Issue.record("expected the refusal to leave it archived")
          return
        }
      }
    }
  }
}
