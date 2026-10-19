#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import LoopCore
import MainHub
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ScriptLifecycleBoundaryTests {
  @Test func aScriptCanArchiveItsOwnSessionAndReturnBeforeStopGrace() async throws {
    try await withToolDeps { _ in
      try await withScriptLifecycle { space, session, owner, worker, _ in
        var world = ToolWorld(worker: worker, owner: owner, session: session)
        let payload = try await world.run("run_script", .object(["source": """
        import { archive } from 'wuhu:session';
        await archive(import.meta.session);
        result('archive returned');
        """]))
        guard case let .script(result) = payload else { throw Mismatch("self-archive did not return its script result: \(payload)") }
        #expect(result.output.hasPrefix("archive returned"))
        guard case .archived = try await space.sessions.record(session).lifecycle else {
          throw Mismatch("self-archive did not commit")
        }
        try await until("self-archiving script releases without advancing stop grace") { await worker.activity().scripts.isEmpty }
        #expect(try await space.sessions.generationState(session).generation == 0)
      }
    }
  }

  @Test func restartCarriesAndDoesNotStopAnAlreadyRunningScript() async throws {
    try await withToolDeps { _ in
      let entered = Gate(), release = Gate()
      try await withDependencies {
        $0.fetch = FetchClient { _ in
          entered.open()
          await release.wait()
          return Response.text("continue")
        }
      } operation: {
        try await withScriptLifecycle { space, session, owner, worker, service in
          defer { release.open() }
          var world = ToolWorld(worker: worker, owner: owner, session: session)
          guard case .script = try await world.run("run_script", .object(["source": """
          result('started');
          await fetch('https://script.test/release');
          if (signal.aborted) throw Error('restart stopped the script');
          update('survived restart');
          """])) else { throw Mismatch("script did not start") }
          await entered.wait()
          let script = try #require(await worker.activity().scripts.first { $0.value == session }?.key)
          let restart = try await service.restart(session, executor: nil, note: "fresh generation")
          #expect(restart.generation == 1)
          #expect(await worker.activity().scripts[script] == session)
          let hydration = try await space.sessions.hydrate(session)
          guard case let .kernel(transcript) = hydration.transcript else { throw Mismatch("restart did not retain a kernel transcript") }
          let head = try #require(transcript.items.compactMap { item -> GenerationHead? in
            if case let .generationHead(head) = item { return head }; return nil
          }.first)
          #expect(head.runningWork == ["script.\(script.rawValue)"])
          release.open()
          try await until("pre-restart script posts from the new generation and releases") {
            let hydration = try await space.sessions.hydrate(session)
            let survived = hydration.undrained.contains { entry in
              if case let .notification(notice) = entry.input { return notice.content.text.contains("survived restart") }
              return false
            }
            let activity = await worker.activity()
            return survived && activity.scripts.isEmpty
          }
          #expect(try await space.sessions.generationState(session).generation == 1)
        }
      }
    }
  }
}

private func withScriptLifecycle(
  _ body: (Space, SessionID, Hub, SessionExecution, SessionService) async throws -> Void,
) async throws {
  let space = try Space.inMemory()
  let session = try await makeSession(space)
  let serviceRef = Box<SessionService?>(nil)
  let owner = Hub(space: space, control: SessionControl { verb, target, force in
    guard verb == .archive, let service = serviceRef.value else { throw Mismatch("unexpected session control") }
    try await service.archive(target, force: force)
  })
  let worker = await firingWorker(owner)
  let service = SessionService(sessions: space.sessions, worker: worker)
  serviceRef.withLock { $0 = service }
  defer { serviceRef.withLock { $0 = nil } }
  do {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await worker.drain() }
      defer { group.cancelAll() }
      try await body(space, session, owner, worker, service)
    }
  } catch {
    await service.shutdown()
    throw error
  }
  await service.shutdown()
}
