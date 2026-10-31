import ControlledTime
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import OperationProtocol
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct MachineV2LeaseSilenceTests {
  @Test func aRouteSilentForALeaseIsKickedWhenThePresenceSaysSo() async throws {
    let clock = VirtualClock()
    let f = try await MachineV2TunnelTests.Fixture()
    let id = f.machine.id
    let kickedAt = Mutex<Duration?>(nil)
    let connection = try await f.hub.attach(.init(pubkey: f.key.pubkeyLabel, machines: [id.rawValue]), client: FetchClient { _ in throw OperationError(.transport) }, abort: {
      kickedAt.withLock { $0 = clock.now.offset }
    })
    let silent = FetchClient { _ in throw OperationError(.requestDeadline) }
    let service = MachineV2Service(space: f.space, hub: f.hub, key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in silent })
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await withDependencies { $0.continuousClock = clock } operation: { try await service.run() } }
      defer { tasks.cancelAll() }
      try await clock.presenceTicks(through: .seconds(40))
      #expect(kickedAt.withLock { $0 } == nil)
      #expect(await f.hub.connection(id) == connection)
      try await clock.presenceTicks(through: .seconds(60))
      #expect(kickedAt.withLock { $0 } == .seconds(60))
      #expect(await f.hub.connection(id) == nil)
      let evidence = try #require(try await f.space.machineV2PresenceEvidence(id.rawValue, group: .shared))
      #expect(evidence.state == .lost && evidence.reason == "leaseSilence")
      await service.shutdown()
    }
  }

  @Test func aTunnelThatReplacesASilentOneGetsALeaseOfItsOwn() async throws {
    let clock = VirtualClock()
    let f = try await MachineV2TunnelTests.Fixture()
    let id = f.machine.id
    let credential = MachineV2Hub.Credential(pubkey: f.key.pubkeyLabel, machines: [id.rawValue])
    let unused = FetchClient { _ in throw OperationError(.transport) }
    let ends = Mutex<[String: Duration]>([:])
    _ = try await f.hub.attach(credential, client: unused, abort: { ends.withLock { $0["first"] = clock.now.offset } })
    let describes = Mutex(0)
    // The machine redials during the describe at 40 s, one tick before the silence reaches the lease; the new tunnel is as silent as the old.
    let silent = FetchClient { _ in
      if describes.withLock({ $0 += 1; return $0 }) == 3 {
        _ = try await f.hub.attach(credential, client: unused, abort: { ends.withLock { $0["second"] = clock.now.offset } })
      }
      throw OperationError(.requestDeadline)
    }
    let service = MachineV2Service(space: f.space, hub: f.hub, key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in silent })
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await withDependencies { $0.continuousClock = clock } operation: { try await service.run() } }
      defer { tasks.cancelAll() }
      try await clock.presenceTicks(through: .seconds(40))
      #expect(ends.withLock { $0 } == ["first": .seconds(40)])
      // The presence loop first sees the new tunnel at 60 s, so its lease runs out at 120 s.
      try await clock.presenceTicks(through: .seconds(100))
      #expect(ends.withLock { $0 } == ["first": .seconds(40)])
      try await clock.presenceTicks(through: .seconds(120))
      #expect(ends.withLock { $0 } == ["first": .seconds(40), "second": .seconds(120)])
      #expect(await f.hub.connection(id) == nil)
      await service.shutdown()
    }
  }

  @Test func aKickForAReplacedTunnelSparesTheTunnelThatReplacedIt() async throws {
    let f = try await MachineV2TunnelTests.Fixture()
    let id = f.machine.id
    let credential = MachineV2Hub.Credential(pubkey: f.key.pubkeyLabel, machines: [id.rawValue])
    let aborted = Mutex<[String]>([])
    let client = FetchClient { _ in throw OperationError(.transport) }
    let first = try await f.hub.attach(credential, client: client, abort: { aborted.withLock { $0.append("first") } })
    let second = try await f.hub.attach(credential, client: client, abort: { aborted.withLock { $0.append("second") } })

    #expect(await f.hub.kick(id, connection: first) == false)
    #expect(await f.hub.connection(id) == second)
    #expect(aborted.withLock { $0 } == ["first"])
    #expect(await f.hub.kick(id, connection: second))
    #expect(await f.hub.connection(id) == nil)
    #expect(aborted.withLock { $0 } == ["first", "second"])
  }
}

private extension VirtualClock {
  /// Steps time one presence tick (a third of the 60 s lease) at a time up to `offset`, returning each time once the presence loop
  /// has described the machine and sleeps toward its next tick.
  func presenceTicks(through offset: Duration) async throws {
    try await sleeping { $0 == .seconds(20) }
    while now.offset < offset {
      advance(to: Self.at(now.offset + .seconds(20)))
      try await sleeping { $0 == .seconds(20) }
    }
  }
}
