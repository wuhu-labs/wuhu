import ControlledTime
import DeterministicDependencies
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies(clock: VirtualClock())) struct CellWriteTests {
  private func hosting(regions: (@Sendable (@escaping RegionSource) -> RegionSource)? = nil, _ body: (Space) async throws -> Void) async throws {
    let space = try Space.inMemory(configuration: Space.makeConfiguration(journalMode: .default), regions: regions)
    space.worker.register(.cell(Scribe.self))
    space.worker.start()
    try await body(space)
    await space.stopWorker()
  }

  @Test func `a row a cell wrote wakes whoever watches its table`() async throws {
    let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let cancel = Mutex<(@Sendable () -> Void)?>(nil)
    try await hosting(regions: { subscribe in
      cancel.withLock { $0 = subscribe(["notifications"], wake) }
      return subscribe
    }) { space in
      defer { cancel.withLock { $0!() } }
      let person = try await space.ensureDevPerson()
      try await space.worker.call(PersonCell.ID(person.account.rawValue)) { try $0.notify(person.persona, PersonNote(source: "s", group: .shared, kind: .sessionSettled, payload: "{}", createdAt: "2026-11-11T00:00:00.000Z")) }
      #expect(space.sessions.notifications(recipient: person.persona).count == 1)
      var woken = wakes.makeAsyncIterator()
      #expect(await woken.next() != nil)

      try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: "fingerprint", certificate: .generated))
      let (clears, clear) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let stopClear = await space.observations.regions(["space_deployment_certificate"], clear)
      defer { stopClear() }
      try await space.recordDeployment(DeploymentRecord(origin: nil, tlsFingerprint: "fingerprint", certificate: nil))
      clear.finish()
      var cleared = clears.makeAsyncIterator()
      #expect(await cleared.next() != nil)
      #expect(try await space.deployment()?.certificate == nil)
    }
  }

  @Test func `a write the data refuses rolls the call back and reaches its caller`() async throws {
    try await hosting { space in
      let (wakes, wake) = AsyncStream<Void>.makeStream()
      let stop = await space.observations.regions(["wuwei_schema"], wake)
      defer { stop() }
      await #expect(throws: ConstraintViolation.self) {
        try await space.worker.call(Scribe.ID("a")) { try $0.twice(7) }
      }
      #expect(space.worker.cell(Scribe.ID("a")).probes() == 0)
      wake.finish()
      var woken = wakes.makeAsyncIterator()
      #expect(await woken.next() == nil)
    }
  }
}
