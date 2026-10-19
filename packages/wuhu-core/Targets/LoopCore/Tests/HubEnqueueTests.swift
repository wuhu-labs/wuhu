import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct HubEnqueueTests {
  @Test func archivedEnqueueCommitsThroughMain() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "fake main", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.archive(id, grace: .seconds(60))
      let input = Fix.message("queued")
      let requests = Box<[String]>([])
      let main = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ async throws in requests.withLock { $0.append("hydrate") } }
        access.beforeAppend = { _, _ async throws in requests.withLock { $0.append("enqueue") } }
        return access
      }())
      let execution = await SessionExecution(main: main, loopConfig: makeConfig())
      #expect(try await execution.enqueue(input, to: id) == 1)
      #expect(requests.value == ["hydrate", "enqueue"])
      await execution.shutdown()
      #expect(try await sessions.undrainedInputs(id).count == 1)
    }
  }
}
