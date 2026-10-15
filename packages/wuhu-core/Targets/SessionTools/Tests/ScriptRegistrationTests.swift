import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ScriptRegistrationTests {
  @Test(arguments: [false, true]) func parentRegistrationPrecedesLaunchAndCancellationCannotLaunch(cancel: Bool) async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let entered = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      defer { entered.continuation.finish(); release.continuation.finish(); gate.cancel() }
      let ended = Box(0)
      let registered = Box(0)
      let owner = InProcessToolOwnerClient(space: space)
      let scripts = Scripts(owner: owner, lifecycle: .init(started: { _, _ in
        registered.withLock { $0 += 1 }
        entered.continuation.yield(())
        await gate.value
      }, ended: { _, _ in ended.withLock { $0 += 1 } }))
      let tools = ToolExecutor(owner: owner, scripts: scripts)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await scripts.run(announceRestart: false) }
        let start = Task { try await scripts.start("result('started')", session: session, lifetime: .seconds(10), tools: tools) }
        for await _ in entered.stream { break }
        #expect(scripts.isIdle)
        #expect(registered.value == 1)
        if cancel { start.cancel() }
        release.continuation.yield(())
        do {
          let execution = try await start.value
          #expect(!cancel)
          #expect(try await execution.answer(within: .seconds(10), onTimeout: .kill) == .result("started"))
        } catch is CancellationError { #expect(cancel) }
        catch { Issue.record(error) }
        do { try await until("registration is released exactly once") { ended.value == 1 && scripts.isIdle } }
        catch { Issue.record(error) }
        #expect(registered.value == 1)
        #expect(ended.value == 1)
        group.cancelAll()
      }
    }
  }
}
