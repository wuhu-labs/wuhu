import DeterministicDependencies
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SessionReadingTests {
  @Test func aReadHandleSeesTheSessionsOwnUncommittedArchive() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let session = try await space.sessions.createSession(group: .shared, title: "Agent", kind: .agent, createdBy: "morgan", model: .test)
      try await space.worker.call(SessionCell.ID(session.rawValue)) { cell in
        #expect(cell._context.session(session).summary?.lifecycle == .live)
        let expiry = try cell.archive(session, grace: .seconds(60))
        let summary = try #require(cell._context.session(session).summary)
        #expect(summary.lifecycle == .archived(graceExpiresAt: expiry))
      }
      await space.stopWorker()
    }
  }
}
