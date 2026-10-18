#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Test func concurrentExecutionShutdownsJoinAndRejectLaterCommands() async throws {
  try await withKernelDeps { _ in
    let sessions = try Space.inMemory().sessions
    let id = try await sessions.createSession(group: .shared, title: "shutdown", kind: .agent, createdBy: "morgan", model: .test)
    let execution = await SessionExecution(main: InProcessMainClient(sessions: sessions), loopConfig: makeConfig())
    try await execution.wake(id)
    async let first: Void = execution.shutdown()
    async let second: Void = execution.shutdown()
    _ = await (first, second)
    await execution.shutdown()
    await #expect(throws: (any Error).self) { try await execution.wake(id) }
  }
}
