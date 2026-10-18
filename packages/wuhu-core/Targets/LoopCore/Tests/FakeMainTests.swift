#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct FakeMainTests {
  @Test func archivedEnqueueUsesOnlyMainMessages() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "fake main", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.archive(id, grace: .seconds(60))
      let snapshot = try await sessions.hydrate(id)
      let input = Fix.message("queued")
      let requests = Box<[String]>([])
      let main = InProcessMainClient { message in
        switch message {
        case .read(id, .hydration):
          requests.withLock { $0.append("hydrate") }
          return .hydration(snapshot)
        case .append(id, .inputEnqueued(input)):
          requests.withLock { $0.append("enqueue") }
          return .queuePosition(42)
        default: throw MainContractError.unexpectedReply
        }
      }
      let execution = await SessionExecution(main: main, loopConfig: makeConfig())
      #expect(try await execution.enqueue(input, to: id) == 42)
      #expect(requests.value == ["hydrate", "enqueue"])
      await execution.shutdown()
      #expect(try await sessions.undrainedInputs(id).isEmpty)
    }
  }
}
