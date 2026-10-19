import SessionTools
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
    let space = try Space.inMemory()
    let sessions = space.sessions
    let id = try await sessions.createSession(group: .shared, title: "shutdown", kind: .agent, createdBy: "morgan", model: .test)
    let execution = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig())
    try await execution.wake(id)
    async let first: Void = execution.shutdown()
    async let second: Void = execution.shutdown()
    _ = await (first, second)
    await execution.shutdown()
    await #expect(throws: (any Error).self) { try await execution.wake(id) }
  }
}
