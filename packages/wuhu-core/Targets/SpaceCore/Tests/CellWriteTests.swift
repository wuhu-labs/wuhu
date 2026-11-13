import ControlledTime
import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing
import Wuwei

@Suite(.deterministicDependencies(clock: VirtualClock())) struct CellWriteTests {
  private func hosting(_ body: (Space) async throws -> Void) async throws {
    let space = try Space.inMemory()
    space.worker.register(.cell(Scribe.self))
    space.worker.start()
    try await body(space)
    await space.stopWorker()
  }

  @Test func `a row a cell wrote wakes whoever watches its table`() async throws {
    try await hosting { space in
      let changes = ChangeSource()
      let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      let stopWatching = changes.subscribe(["notifications"], wake)
      defer { stopWatching() }
      let writer = await space.writer
      writer.add(transactionObserver: ChangeSourceFeeder(changes), extent: .databaseLifetime)
      try await space.worker.call(PersonCell.ID("owner")) { try $0.notify("owner", PersonNote(source: "s", group: .shared, kind: .sessionSettled, payload: "{}", createdAt: "2026-11-11T00:00:00.000Z")) }
      #expect(space.sessions.notifications(recipient: "owner").count == 1)
      var woken = wakes.makeAsyncIterator()
      #expect(await woken.next() != nil)
    }
  }

  @Test func `a write the data refuses rolls the call back and reaches its caller`() async throws {
    try await hosting { space in
      await #expect(throws: ConstraintViolation.self) {
        try await space.worker.call(Scribe.ID("a")) { try $0.twice(7) }
      }
      let kept = try await space.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM wuwei_schema WHERE kind = 'scribe-probe'")! }
      #expect(kept == 0)
    }
  }
}
