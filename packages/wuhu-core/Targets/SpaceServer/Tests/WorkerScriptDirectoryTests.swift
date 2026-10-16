#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@testable import SpaceServer
import Synchronization
import Testing

@Suite struct WorkerScriptDirectoryTests {
  @Test func stopUsesScriptOwnerRatherThanCurrentActorPlacementAndRefusesForeignSession() async throws {
    let directory = WorkerScriptDirectory()
    let generation = UUID(), replacement = UUID()
    let session = SessionID("owner")
    let effects = Mutex<[String]>([])
    await directory.bind(generation) { script, caller in
      #expect(caller == session)
      effects.withLock { $0.append("old:\(script)") }
      return .script(.init(output: "stopped"))
    }
    await directory.bind(replacement) { script, _ in
      effects.withLock { $0.append("new:\(script)") }
      return .script(.init(output: "wrong"))
    }
    try await directory.started("script", session: session, generation: generation)
    let refused = try await directory.stop("script", session: .init("foreign"))
    guard case .failure = refused else { Issue.record("foreign script stop was accepted"); return }
    #expect(effects.withLock { $0.isEmpty })
    _ = try await directory.stop("script", session: session)
    #expect(effects.withLock { $0 } == ["old:script"])
    await directory.ended("script", session: session, generation: replacement)
    #expect(await directory.contains(generation))
    await directory.ended("script", session: session, generation: generation)
    #expect(await !directory.contains(generation))
    await directory.shutdown()
  }

  // A loaded run can leave this test's tasks waiting seconds for an executor
  // slot, so it waits on the control's own signal, bounded by the time limit.
  @Test(.timeLimit(.minutes(1))) func stopResponsePinsGenerationAfterTheScriptExitNotification() async throws {
    let directory = WorkerScriptDirectory()
    let generation = UUID()
    let session = SessionID("owner")
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let gate = Task { for await _ in release.stream { break } }
    defer { release.continuation.finish(); gate.cancel() }
    await directory.bind(generation) { _, _ in
      await directory.ended("script", session: session, generation: generation)
      entered.continuation.finish()
      await gate.value
      return .script(.init(output: "stopped"))
    }
    try await directory.started("script", session: session, generation: generation)
    let stopping = Task { try await directory.stop("script", session: session) }
    for await _ in entered.stream {}
    #expect(await directory.scripts(for: session).isEmpty)
    #expect(await directory.contains(generation))
    release.continuation.yield(())
    _ = try await stopping.value
    #expect(await !directory.contains(generation))
    await directory.shutdown()
  }

  @Test func archiveStopsScriptsAcrossEveryRetainedGenerationAndLossClearsOnlyThatGeneration() async throws {
    let directory = WorkerScriptDirectory()
    let first = UUID(), second = UUID()
    let session = SessionID("owner")
    let stopped = Mutex<Set<String>>([])
    for generation in [first, second] {
      await directory.bind(generation) { script, _ in
        _ = stopped.withLock { $0.insert(script) }
        return .script(.init(output: "stopped"))
      }
    }
    try await directory.started("one", session: session, generation: first)
    try await directory.started("two", session: session, generation: second)
    try await directory.started("foreign", session: .init("foreign"), generation: second)
    try await directory.stopAll(session)
    #expect(stopped.withLock { $0 } == ["one", "two"])
    await directory.lost(first)
    #expect(await directory.scripts(for: session) == ["two"])
    #expect(await directory.contains(second))
    await directory.shutdown()
  }
}
