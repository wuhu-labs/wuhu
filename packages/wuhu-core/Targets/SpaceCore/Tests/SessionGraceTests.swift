import ControlledTime
import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

struct SessionGraceTests {
  private func makeControlledSpace() throws -> (Space, TimeControl) {
    try withDependencies {
      $0.installTimeControl()
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.timeControl) var timeControl
      return (try Space.inMemory(), timeControl)
    }
  }

  @Test func archivedSessionAcceptsEnqueueOnlyWithinGrace() async throws {
    let (space, time) = try makeControlledSpace()
    let store = space.sessions
    let anchor = Date(timeIntervalSinceReferenceDate: 0)
    let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

    let deadline = try await store.archive(sid, grace: .seconds(3600))
    #expect(deadline == anchor.addingTimeInterval(3600))
    #expect(try await store.record(sid).lifecycle == .archived(graceExpiresAt: deadline))

    let early = SessionFix.message("in time")
    #expect(try await store.enqueue(sid, input: early) == 1)
    #expect(try await store.record(sid).work == .hasWork)

    await time.advance(to: anchor.addingTimeInterval(7200))
    await #expect(throws: SessionStoreError.archiveGraceExpired(sid.rawValue)) {
      _ = try await store.enqueue(sid, input: SessionFix.message("too late"))
    }
    // The retained dedup row still answers a retry of the pre-deadline item.
    #expect(try await store.enqueue(sid, input: early) == 1)
    await #expect(throws: SessionStoreError.archiveGraceExpired(sid.rawValue)) {
      try await store.unarchive(sid)
    }
  }

  @Test func unarchiveWithinGraceRestoresLive() async throws {
    let (space, time) = try makeControlledSpace()
    let store = space.sessions
    let anchor = Date(timeIntervalSinceReferenceDate: 0)
    let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
    _ = try await store.enqueue(sid, input: SessionFix.message())
    _ = try await store.archive(sid, grace: .seconds(3600))
    #expect(try await store.bootSessions() == [])

    await time.advance(to: anchor.addingTimeInterval(1800))
    try await store.unarchive(sid)
    let record = try await store.record(sid)
    #expect(record.lifecycle == .live)
    #expect(record.work == .hasWork)
    #expect(try await store.bootSessions() == [sid])
  }
}
