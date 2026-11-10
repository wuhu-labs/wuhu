import ControlledTime
import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Synchronization
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
      let wakes = Mutex(0)
      let writer = await space.writer
      let watch = DatabaseRegionObservation(tracking: [Table("notifications")]).start(
        in: writer, onError: { _ in }, onChange: { _ in wakes.withLock { $0 += 1 } },
      )
      defer { watch.cancel() }
      let rows = try await space.worker.call(Scribe.ID("a")) { try $0.note("carol") }
      #expect(rows == 1)
      #expect(wakes.withLock { $0 } == 1)
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
