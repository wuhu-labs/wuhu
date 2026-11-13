import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct CapacityRetryTests {
  @Test(arguments: ["response_too_large", "websocket_message_too_large"])
  func providerOversizeCompactsOnceThenKeepsCode(code: String) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let error = InferenceError.capacityExceeded(code: code, message: "payload too large", status: 413)
      let script = InferenceScript([Fix.failing(error), Fix.failing(error), Fix.replying("must not run")])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let sid = try await sessions.createSession(group: .shared, title: "capacity size", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 2)
      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(try await sessions.record(sid).errorMessage == String(describing: error))
    }
  }
}
