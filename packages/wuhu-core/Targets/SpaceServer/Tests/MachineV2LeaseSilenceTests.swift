import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct MachineV2LeaseSilenceTests {
  @Test func aRouteSilentForALeaseIsKickedWhenThePresenceSaysSo() async throws {
    try await withLeaseSpace { space, date in
      let machine = try await space.addMachineV2(name: "silent").machine.id
      let cell = MachineCell.ID(machine.rawValue)
      let box = try await LeaseBox(space: space, cell: cell)
      try await box.describe()
      box.peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))))
      try await leaseStep { space.worker.cell(cell).presence.state == "attached" }
      let answered = try #require(try await space.machineV2PresenceEvidence(machine.rawValue, group: .shared))
      #expect(answered.state == .attached)

      for elapsed in [20.0, 40.0] {
        date.value.withLock { $0 = leaseOrigin.addingTimeInterval(elapsed) }
        try await space.worker.call(cell) { try $0.wake() }
        try await box.describe()
        box.peer.send(.init(tag: .describe, answer: .transport(.init(.requestDeadline))))
        try await leaseStep { space.worker.cell(cell).presence.describeDeadline == nil }
        #expect(!box.closed.isOpen)
        #expect(space.worker.cell(cell).presence.lease == Int64((leaseOrigin.timeIntervalSince1970 + 60) * 1000))
      }
      date.value.withLock { $0 = leaseOrigin.addingTimeInterval(60) }
      try await space.worker.call(cell) { try $0.wake() }
      await box.closed.wait()
      let evidence = try #require(try await space.machineV2PresenceEvidence(machine.rawValue, group: .shared))
      #expect(evidence.state == .lost && evidence.reason == "leaseSilence")
      #expect(evidence.observedAt == answered.observedAt)
    }
  }

  @Test func aDescribedReplacementGetsALeaseOfItsOwn() async throws {
    try await withLeaseSpace { space, date in
      let cell = MachineCell.ID(try await space.addMachineV2(name: "replacement").machine.id.rawValue)
      let first = try await LeaseBox(space: space, cell: cell)
      try await first.describe()
      first.peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))))
      try await waitForMachineDescription(cell, in: space)
      date.value.withLock { $0 = leaseOrigin.addingTimeInterval(40) }
      let second = try await LeaseBox(space: space, cell: cell)
      try await second.describe()
      await first.closed.wait()
      second.peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))))
      try await waitForMachineDescription(cell, in: space)
      #expect(!second.closed.isOpen)
      for elapsed in [60.0, 99.0] {
        date.value.withLock { $0 = leaseOrigin.addingTimeInterval(elapsed) }
        try await space.worker.call(cell) { try $0.wake() }
        #expect(!second.closed.isOpen)
        #expect(space.worker.cell(cell).presence.lease == Int64((leaseOrigin.timeIntervalSince1970 + 100) * 1000))
      }
      date.value.withLock { $0 = leaseOrigin.addingTimeInterval(100) }
      try await space.worker.call(cell) { try $0.wake() }
      await second.closed.wait()
      #expect(space.worker.cell(cell).presence.state == "lost")
    }
  }

  @Test func aStaleSocketCloseAndAnswerSpareTheSocketThatReplacedIt() async throws {
    try await withLeaseSpace { space, date in
      let cell = MachineCell.ID(try await space.addMachineV2(name: "stale").machine.id.rawValue)
      let first = try await LeaseBox(space: space, cell: cell)
      try await first.describe()
      let second = try await LeaseBox(space: space, cell: cell)
      try await second.describe()
      await first.closed.wait()
      date.value.withLock { $0 = leaseOrigin.addingTimeInterval(1) }
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      second.peer.send(.init(tag: .describe, answer: .description(description)))
      try await leaseStep { space.worker.cell(cell).machineDescription?.instance == description.instance }
      first.peer.send(.init(tag: .describe, answer: .transport(.init(.requestDeadline))))
      first.peer.close()
      _ = try await space.worker.call(cell) { _ in true }
      #expect(!second.closed.isOpen)
      #expect(space.worker.cell(cell).machineDescription?.instance == description.instance)
      #expect(space.worker.cell(cell).presence.lease == Int64((leaseOrigin.timeIntervalSince1970 + 61) * 1000))
      date.value.withLock { $0 = leaseOrigin.addingTimeInterval(60) }
      try await space.worker.call(cell) { try $0.wake() }
      #expect(!second.closed.isOpen)
      second.peer.close()
    }
  }
}

private let leaseOrigin = Date(timeIntervalSince1970: 1_000_000)

private final class LeaseDate: Sendable {
  let value = Mutex(leaseOrigin)
}

private func withLeaseSpace<R>(_ body: (Space, LeaseDate) async throws -> R) async throws -> R {
  let date = LeaseDate()
  return try await withDependencies {
    $0.date = DateGenerator { date.value.withLock { $0 } }
  } operation: {
    let space = try Space.inMemory()
    do {
      let result = try await body(space, date)
      try await space.close()
      return result
    } catch {
      try await space.close()
      throw error
    }
  }
}

private struct LeaseBox {
  let peer: Peer<BoxSocket>
  let requests: AsyncStream<BoxSocket.Outgoing>
  let closed: Gate

  init(space: Space, cell: MachineCell.ID) async throws {
    let (requests, continuation) = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let closed = Gate()
    let pubkey = try await seedBoxKey(space: space, machine: cell.key)
    peer = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) { event in
      switch event {
      case let .frame(request): continuation.yield(request)
      case .closed: closed.open(); continuation.finish()
      }
    })
    self.requests = requests
    self.closed = closed
  }

  func describe() async throws {
    var iterator = requests.makeAsyncIterator()
    let request = try #require(await iterator.next())
    #expect(request.tag == .describe)
    guard case .describe = request.exchange else { Issue.record("expected describe exchange"); return }
  }
}

private struct LeaseStepDidNotProgress: Error {}

private func leaseStep(_ predicate: () -> Bool) async throws {
  for _ in 0 ..< 20000 {
    if predicate() { return }
    try Task.checkCancellation()
    await Task.yield()
  }
  Issue.record("BoxSocket did not commit the expected presence step")
  throw LeaseStepDidNotProgress()
}
