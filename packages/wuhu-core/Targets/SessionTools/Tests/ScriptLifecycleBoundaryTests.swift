import DeterministicDependencies
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
@testable import SessionTools
import SpaceCore
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct ScriptLifecycleBoundaryTests {
  @Test func aScriptCanArchiveItsOwnSessionAndReturnBeforeStopGrace() async throws {
    try await withToolDeps { _ in
      try await withScriptLifecycle { space, session, owner, worker in
        var world = ToolWorld(worker: worker, session: session)
        let payload = try await world.run("run_script", .object(["source": """
        import { archive } from 'wuhu:session';
        await archive(import.meta.session);
        result('archive returned');
        """]))
        guard case let .script(result) = payload else { throw Mismatch("self-archive did not return its script result: \(payload)") }
        #expect(result.output.hasPrefix("archive returned"))
        try await until("self-archive commits") { try await space.sessions.record(session).lifecycle != .live }
        try await until("self-archiving script releases without advancing stop grace") { worker.tools.scripts!.running(of: session).isEmpty }
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
        try await withScriptLifecycle { space, session, owner, worker in
          defer { release.open() }
          var world = ToolWorld(worker: worker, session: session)
          guard case .script = try await world.run("run_script", .object(["source": """
          result('started');
          await fetch('https://script.test/release');
          if (signal.aborted) throw Error('restart stopped the script');
          update('survived restart');
          """])) else { throw Mismatch("script did not start") }
          await entered.wait()
          let script = try #require(worker.tools.scripts!.running(of: session).first)
          let restart = try await worker.restart(session, executor: nil, note: "fresh generation")
          #expect(restart.generation == 1)
          #expect(worker.tools.scripts!.running(of: session) == [script])
          try await until("restarted") { try await space.sessions.generationState(session).generation == 1 }
          let hydration = try await space.sessions.hydrate(session)
          guard case let .kernel(transcript) = hydration.transcript else { throw Mismatch("restart did not retain a kernel transcript") }
          let head = try #require(transcript.items.compactMap { item -> GenerationHead? in
            if case let .generationHead(head) = item { return head }; return nil
          }.first)
          #expect(head.runningWork == [script])
          release.open()
          try await until("pre-restart script posts from the new generation and releases") {
            let survived = try await handlerNotifications(space, session).contains { $0.content.text.contains("survived restart") }
            return survived && worker.tools.scripts!.running(of: session).isEmpty
          }
          #expect(try await space.sessions.generationState(session).generation == 1)
        }
      }
    }
  }
}

private func withScriptLifecycle(
  _ body: (Space, SessionID, Hub, SessionExecution) async throws -> Void,
) async throws {
  let space = try Space.inMemory()
  let session = try await makeSession(space)
  let owner = Hub(space: space)
  let worker = await firingWorker(owner)
  do {
    try await body(space, session, owner, worker)
  } catch {
    await worker.shutdown()
    throw error
  }
  await worker.shutdown()
}
