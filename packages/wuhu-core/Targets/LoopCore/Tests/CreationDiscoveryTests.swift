import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct CreationDiscoveryTests {
  @Test func `a newly created session without a head wakes inert`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let config = makeConfig()
      try await runService(space, config) { service in
        try await sessions.look(sid)
        try await until("the cell has looked") { try await sessions.settledWork(sid) }
      }
      #expect(try await sessions.lines(sid).isEmpty)
    }
  }
}
