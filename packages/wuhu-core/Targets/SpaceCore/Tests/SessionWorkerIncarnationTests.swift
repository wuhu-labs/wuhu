import Dependencies
import Foundation
import Scratch
import SessionDomain
import SpaceCore
import Synchronization
import Testing

@Suite struct SessionWorkerIncarnationTests {
  @Test func deathsSurviveReopenAttributeOnlyActiveSessionsAndExpire() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1000))
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.withLock { $0 } } } operation: {
        let scratch = try ScratchFolder("worker-deaths")
        defer { scratch.remove() }
        let file = scratch.url.appendingPathComponent("space.sqlite")
        let store = try Space.open(file: file).sessions
        let a = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "owner", model: .test)
        let b = try await store.createSession(group: .shared, title: "b", kind: .agent, createdBy: "owner", model: .test)
        _ = try await store.enqueue(b, input: SessionFix.message())
        for index in 0 ..< 3 {
          let incarnation = UUID()
          let reopened = try Space.open(file: file).sessions
          try await reopened.setWorkerActivity(a, incarnation: incarnation, active: true)
          try await reopened.setWorkerActivity(b, incarnation: incarnation, active: true)
          try await reopened.setWorkerActivity(b, incarnation: incarnation, active: false)
          // Parent replacement finalizes orphaned active leases; ordinary child loss names the incarnation.
          let losses = try await Space.open(file: file).sessions.recordWorkerLoss(incarnation: index == 1 ? nil : incarnation)
          #expect(losses == [a: index == 2])
          #expect(try await reopened.recordWorkerLoss(incarnation: incarnation).isEmpty)
          #expect(try await reopened.workerCrashFenced(a) == (index == 2))
          #expect(try await reopened.workerCrashFenced(b) == false)
          time.withLock { $0.addTimeInterval(1) }
        }
        #expect(try await Space.open(file: file).sessions.workerCrashFenced(a))
        time.withLock { $0.addTimeInterval(600) }
        #expect(try await Space.open(file: file).sessions.workerCrashFenced(a) == false)
        #expect(try await store.undrainedInputs(b).count == 1)
      }
    }
  }
}
