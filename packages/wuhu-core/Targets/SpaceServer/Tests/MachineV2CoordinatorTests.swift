#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Crypto
import Fetch
import GRDB
import OperationClient
import OperationProtocol
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private actor RecoveryRoute {
  let id: UUID
  let token = UUID()
  let bytes = Data(repeating: 42, count: 70000)
  var available = false
  var terminal = false
  var acknowledged: UInt64 = 0
  var calls: [(String, String)] = []
  var reasons: [String] = []
  init(id: UUID) { self.id = id }
  func attach() { available = true }
  func fetch(_ request: Request) async throws -> Response {
    calls.append((request.method.rawValue, request.url.path))
    guard available else { throw OperationError(.transport) }
    if request.method == .post { throw OperationError(.invalidInput, message: "start replay") }
    if request.url.path.hasSuffix("/stop") {
      reasons.append(try await request.json(StopRequest.self).reason)
      terminal = true
    }
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let channel = query.first { $0.name == "channel" }?.value
    let after = query.first { $0.name == "after" }?.value.flatMap(UInt64.init) ?? 0
    var payload: ChannelPayload?
    var through: Offset?
    if channel != nil {
      acknowledged = after
      let end = min(bytes.count, Int(after) + 65536)
      payload = .init(data: bytes.subdata(in: Int(after) ..< end))
      through = .init(rawValue: UInt64(end))
    }
    return recoveryReply(try .json(OperationSnapshot(
      operation: id,
      verdict: terminal ? .init(.stopped, reason: "serverRestart") : nil,
      terminalToken: terminal ? token : nil,
      finalOffsets: terminal ? ["out": .init(rawValue: UInt64(bytes.count))] : [:],
      outputConsumed: acknowledged == UInt64(bytes.count),
      channel: channel,
      from: channel == nil ? nil : .init(rawValue: after),
      through: through,
      payload: payload,
      channelEnd: terminal && through?.rawValue == UInt64(bytes.count),
    )), to: request)
  }
}

@Suite(.timeLimit(.minutes(1))) struct MachineV2CoordinatorTests {
  @Test func networkFreePreparePersistsAllStopIntentsAndSharedClientIdentity() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let first = Self.record(); let second = Self.record()
    _ = try await store.claim(.init(scope: "dead-script-one", key: "one"), record: first)
    _ = try await store.claim(.init(scope: "dead-script-two", key: "two"), record: second)
    _ = try await store.transaction(first.id) { $0.committed["out"] = .init(rawValue: 3); $0.output["out"] = [.init(data: Data([1, 2, 3]))] }
    _ = try await store.transaction(second.id) { $0.stopReason = "callerDeadline"; $0.callerRemainingMs = 123 }
    let route = RecoveryRoute(id: first.id)
    let coordinator = Self.coordinator(space: space, key: key, route: route)
    try await coordinator.prepare()
    #expect(await route.calls.isEmpty)
    #expect(try await store.read(first.id).stopReason == "serverRestart")
    #expect(try await store.read(first.id).output.isEmpty)
    #expect(try await store.read(first.id).committed["out"]?.rawValue == 3)
    #expect(try await store.read(second.id).stopReason == "callerDeadline")
    #expect(try await store.read(second.id).callerRemainingMs == 0)
    let one = try await coordinator.client(group: .shared)
    let two = try await coordinator.client(group: .shared)
    #expect(one === two)
    await coordinator.shutdown()
    await #expect(throws: OperationError.self) { try await coordinator.client(group: .shared) }
  }

  @Test func absentStartupRouteKeepsStopIntentAndHonestFullLeaseThenReconnectDrainsAndAcks() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    let route = RecoveryRoute(id: record.id); let time = MachineRecoveryTestClock()
    let coordinator = Self.coordinator(space: space, key: key, route: route, clock: time.clock)
    try await coordinator.prepare()
    try await coordinator.tick()
    #expect(try await store.read(record.id).unknown == nil)
    await time.advance(.seconds(59))
    try await coordinator.tick()
    #expect(try await store.read(record.id).unknown == nil)
    await time.advance(.seconds(2))
    try await coordinator.tick()
    #expect(try await store.read(record.id).unknown?.details?.object?["reason"]?.stringValue == "leaseSilence")
    #expect(try await store.read(record.id).stopReason != nil)
    await route.attach()
    for _ in 0 ..< 4 { try await coordinator.tick() }
    let restored = try await store.read(record.id)
    #expect(restored.unknown == nil)
    #expect(restored.snapshot?.verdict?.tag == .stopped)
    #expect(restored.committed["out"]?.rawValue == 70000)
    #expect(restored.output.isEmpty)
    #expect(restored.snapshot?.outputConsumed == true)
    #expect(await route.calls.allSatisfy { $0.0 != "POST" })
    let before = await route.calls.count
    try await coordinator.tick()
    #expect(await route.calls.count == before)
    await coordinator.shutdown()
  }

  @Test func unansweredClaimIsNeverStartedAndDefinitiveUnknownFinishesRecovery() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "died-before-dispatch", key: "one"), record: record)
    let calls = Mutex<[String]>([])
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: MachineRecoveryTestClock().clock, fetch: { _ in
      FetchClient { request in
        calls.withLock { $0.append(request.method.rawValue) }
        return recoveryReply(try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound), to: request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    try await coordinator.tick()
    #expect(try await store.read(record.id).unknown?.code == .unknownOperation)
    #expect(calls.withLock { $0 } == ["PUT"])
    try await coordinator.tick()
    #expect(calls.withLock { $0 } == ["PUT"])
    await coordinator.shutdown()
  }

  private static func record() -> ClientRecord {
    let descriptor = KindDescriptor("query.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("out", windowBytes: 131_072)])
    return .init(id: UUID(), correlation: UUID(), machine: "test", start: .init(kind: "query.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [descriptor]))
  }

  private static func coordinator(space: Space, key: SymmetricKey, route: RecoveryRoute, clock: OperationClock = MachineRecoveryTestClock().clock) -> MachineV2Coordinator {
    MachineV2Coordinator(
      space: space,
      key: key,
      problemsGroup: .shared,
      origin: URL(string: "http://test.invalid")!,
      clock: clock,
      fetch: { _ in FetchClient { try await route.fetch($0) } },
      abort: { _, _ in },
    )
  }
}

private actor LeaveRoute {
  var failAcknowledgement = true
  var forbidden: Set<String> = []
  var requests: [URL] = []
  func allowAcknowledgement() { failAcknowledgement = false }
  func forbid(_ id: String) { forbidden.insert(id) }
  func fetch(_ request: Request) throws -> Response {
    requests.append(request.url)
    if forbidden.contains(request.url.lastPathComponent) {
      return recoveryReply(try .json(ErrorEnvelope(.init(.machineNotAuthorized)), status: .forbidden), to: request)
    }
    if request.url.query?.contains("leaveAck=true") == true, failAcknowledgement { throw OperationError(.transport) }
    return recoveryReply(try .json(ErrorEnvelope(.init(.leaving)), status: .conflict), to: request)
  }
}

extension MachineV2CoordinatorTests {
  @Test func lostLeaveAcknowledgementNeverPretendsDetachedAndRetriesHandshake() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let machine = try await space.addMachine(name: "leave-test")
    try await space.registerMachineV2(machine.id.rawValue, group: .shared)
    let route = LeaveRoute(); let time = MachineRecoveryTestClock()
    let coordinator = MachineV2Coordinator(
      space: space,
      key: key,
      problemsGroup: .shared,
      origin: URL(string: "http://test.invalid")!,
      clock: time.clock,
      fetch: { _ in FetchClient { try await route.fetch($0) } },
      abort: { _, _ in },
    )
    try await coordinator.prepare(); try await coordinator.tick()
    let lost = try await Self.presenceRows(space)
    #expect(lost == [[machine.id.rawValue, "lost", "leaveHandshakeFailed"]])
    await route.allowAcknowledgement(); await time.advance(.seconds(20))
    try await coordinator.tick()
    let settled = try await Self.presenceRows(space)
    #expect(settled == [[machine.id.rawValue, "detached", "leaving"]])
    #expect(await route.requests.filter { $0.query == "leaveAck=true" }.count == 2)
    await coordinator.shutdown()
  }

  @Test func revokedRouteDoesNotDisableOtherMachineProbes() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let revoked = try await space.addMachine(name: "revoked")
    let healthy = try await space.addMachine(name: "healthy")
    try await space.registerMachineV2(revoked.id.rawValue, group: .shared)
    try await space.registerMachineV2(healthy.id.rawValue, group: .shared)
    let route = LeaveRoute(); await route.allowAcknowledgement(); await route.forbid(revoked.id.rawValue)
    let coordinator = MachineV2Coordinator(
      space: space,
      key: key,
      problemsGroup: .shared,
      origin: URL(string: "http://test.invalid")!,
      clock: MachineRecoveryTestClock().clock,
      fetch: { _ in FetchClient { try await route.fetch($0) } },
      abort: { _, _ in },
    )
    try await coordinator.prepare(); try await coordinator.tick()
    let states = try await Self.presenceRows(space)
    #expect(states.contains([revoked.id.rawValue, "lost", "machineNotAuthorized"]))
    #expect(states.contains([healthy.id.rawValue, "detached", "leaving"]))
    _ = try await coordinator.client(group: .shared)
    await coordinator.shutdown()
  }
}

import OperationRuntime

private struct RecoveryOutputKind: OperationKind {
  struct Input: Codable, Sendable {}
  let descriptor = KindDescriptor("recovery.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("out")])
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> Bool {
    try await channels.send(.init(data: Data("retained-at-restart".utf8)), to: "out")
    return true
  }
}

extension MachineV2CoordinatorTests {
  @Test func productionAgentRetainedOutputIsDrainedAndTerminalAckAllowsLeave() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let time = TestClock<Duration>(); let origin = time.now
    let clock = OperationClock(now: { origin.duration(to: time.now) }, sleep: { try await time.sleep(for: $0) })
    let agent = try OperationAgent(machine: "test", kinds: [.init(RecoveryOutputKind())], clock: clock, authorize: { _, _ in })
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      do {
        let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
        let fetch = FetchClient { try await agent.handler($0) }
        let first = try OperationClient(origin: URL(string: "http://test.invalid")!, fetch: fetch, clock: clock, store: store, abort: { _ in }, trace: { _ in })
        _ = try await first.describe("test")
        let id = try await first.start("test", request: .init(kind: "recovery.v1", input: [:]), owner: .init(scope: "dead-script", key: "one"))
        var terminal = try await first.poll(id)
        #expect(terminal.verdict == nil)
        tasks.addTask { await agent.run() }
        while terminal.verdict == nil {
          try Task.checkCancellation()
          terminal = try await first.poll(id)
        }
        #expect(terminal.verdict?.tag == .completed)
        #expect(terminal.finalOffsets["out"]?.rawValue == 19)
        #expect(!terminal.outputConsumed)
        await first.shutdown()
        await agent.leave()
        #expect(await !agent.departureSettled())
        let coordinator = MachineV2Coordinator(
          space: space,
          key: key,
          problemsGroup: .shared,
          origin: URL(string: "http://test.invalid")!,
          clock: clock,
          fetch: { _ in fetch },
          abort: { _, _ in },
        )
        try await coordinator.prepare()
        for _ in 0 ..< 3 { try await coordinator.tick() }
        let recovered = try await store.read(id)
        #expect(recovered.committed["out"]?.rawValue == 19)
        #expect(recovered.snapshot?.outputConsumed == true)
        #expect(recovered.snapshot?.verdict?.tag == .completed)
        #expect(await agent.departureSettled())
        let description = try await agent.handler(.init(url: URL(string: "http://test.invalid/machine/v2/machines/test")!))
        #expect(try await description.json(ErrorEnvelope.self).error.code == .leaving)
        await coordinator.shutdown()
        await agent.shutdown(); tasks.cancelAll()
      } catch { await agent.shutdown(); tasks.cancelAll(); throw error }
    }
  }
}

extension MachineV2CoordinatorTests {
  private static func presenceRows(_ space: Space) async throws -> [[String]] {
    try await space.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT machine_id, state, reason FROM machine_v2_presence WHERE grp = 'shared' ORDER BY machine_id").map {
        [$0["machine_id"], $0["state"], $0["reason"]]
      }
    }
  }
}

extension MachineV2CoordinatorTests {
  @Test func ownedRunAndShutdownJoinRecoveryAndRejectNewClientCreation() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    let (entered, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, fetch: { _ in
      FetchClient { _ in continuation.yield(()); throw OperationError(.transport) }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await coordinator.run() }
      for await _ in entered { break }
      continuation.finish()
      await coordinator.shutdown()
      while try await tasks.next() != nil {}
    }
    #expect(try await store.read(record.id).stopReason == "serverRestart")
    await #expect(throws: OperationError.self) { try await coordinator.client(group: .shared) }
  }
}

extension MachineV2CoordinatorTests {
  @Test func confirmedDetachedSurvivesServerRestartAndReattachesOnlyOnDescriptionEvidence() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let machine = try await space.addMachine(name: "prior-goodbye")
    try await space.registerMachineV2(machine.id.rawValue, group: .shared)
    try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .detached, reason: "leaving")
    let time = MachineRecoveryTestClock(); let attached = Mutex(false)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: time.clock, fetch: { _ in
      FetchClient { request in
        guard attached.withLock({ $0 }) else { throw OperationError(.transport) }
        return recoveryReply(try .json(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])), to: request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare(); try await coordinator.tick()
    await time.advance(.seconds(60)); try await coordinator.tick()
    #expect(try await space.machineV2DetachedMembers(group: .shared) == [machine.id.rawValue])
    #expect(try await Self.presenceRows(space) == [[machine.id.rawValue, "detached", "leaving"]])
    attached.withLock { $0 = true }; await time.advance(.seconds(20)); try await coordinator.tick()
    #expect(try await space.machineV2DetachedMembers(group: .shared).isEmpty)
    #expect(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.state == .attached)
    await coordinator.shutdown()
  }
}

private func recoveryReply(_ reply: Response, to request: Request) -> Response {
  var response = reply
  response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
  response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
  response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
  return response
}

extension MachineV2CoordinatorTests {
  @Test func abandonedOperationAuthorizationFailureIsIsolatedAndStillWaitsFullSilenceLease() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let revoked = Self.record(); let healthy = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "revoked"), record: revoked)
    _ = try await store.claim(.init(scope: "dead-script", key: "healthy"), record: healthy)
    let route = RecoveryRoute(id: healthy.id); await route.attach(); let time = MachineRecoveryTestClock()
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: time.clock, fetch: { _ in
      FetchClient { request in
        if request.url.path.contains(revoked.id.uuidString) {
          return recoveryReply(try .json(ErrorEnvelope(.init(.machineNotAuthorized)), status: .forbidden), to: request)
        }
        return try await route.fetch(request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    for _ in 0 ..< 3 { try await coordinator.tick() }
    #expect(try await store.read(healthy.id).snapshot?.outputConsumed == true)
    #expect(try await store.read(revoked.id).unknown == nil)
    await time.advance(.seconds(59)); try await coordinator.tick()
    #expect(try await store.read(revoked.id).unknown == nil)
    await time.advance(.seconds(1)); try await coordinator.tick()
    #expect(try await store.read(revoked.id).unknown?.details?.object?["reason"]?.stringValue == "leaseSilence")
    #expect(try await store.read(revoked.id).stopReason != nil)
    await coordinator.shutdown()
  }

  @Test func fatalTraceFailureEndsOwnedRunAndClosesClientAdmission() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: MachineRecoveryTestClock().clock, fetch: { _ in
      FetchClient { _ in throw OperationError(.traceUnavailable) }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    do { try await coordinator.run(); Issue.record("fatal trace failure swallowed") }
    catch let error as OperationError { #expect(error.code == .traceUnavailable) }
    await #expect(throws: OperationError.self) { try await coordinator.client(group: .shared) }
  }
}

extension MachineV2CoordinatorTests {
  @Test func expiredRemoteTerminalReceiptCannotErasePersistedCompletion() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    _ = try await store.transaction(record.id) {
      $0.snapshot = .init(operation: record.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: true)
    }
    let calls = Mutex(0)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: MachineRecoveryTestClock().clock, fetch: { _ in
      FetchClient { request in
        calls.withLock { $0 += 1 }
        #expect(request.method == .get)
        return recoveryReply(try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound), to: request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare(); try await coordinator.tick()
    #expect(try await store.read(record.id).snapshot?.verdict?.tag == .completed)
    #expect(try await store.read(record.id).unknown == nil)
    try await coordinator.tick()
    #expect(calls.withLock { $0 } == 0)
    await coordinator.shutdown()
  }
}

extension MachineV2CoordinatorTests {
  @Test func locallyPrunedReceiptRetiresOnlyItsWorkerWhileOwnedRunDrainsNeighbor() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let expired = Self.record(); let healthy = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "expired"), record: expired)
    _ = try await store.transaction(expired.id) {
      $0.snapshot = .init(operation: expired.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: true)
    }
    _ = try await store.claim(.init(scope: "dead-script", key: "healthy"), record: healthy)
    let route = RecoveryRoute(id: healthy.id); await route.attach()
    let (acknowledged, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let clock = OperationClock(now: { .zero }, sleep: { duration in
      if try await store.read(healthy.id).snapshot?.outputConsumed == true { continuation.yield(()) }
      try await ContinuousClock().sleep(for: duration)
    })
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "http://test.invalid")!, clock: clock, fetch: { _ in
      FetchClient { request in
        #expect(!request.url.path.contains(expired.id.uuidString))
        return try await route.fetch(request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE machine_v2_retention SET expired_at = '2000-01-01T00:00:00.000Z' WHERE id = ?", arguments: [expired.id.uuidString])
      try db.execute(sql: "DELETE FROM machine_v2_maintenance WHERE id = 'receipts/shared'")
    }
    _ = try await store.claim(.init(scope: "live-script", key: "trigger-retention"), record: Self.record())
    do { _ = try await store.read(expired.id); Issue.record("expired local receipt was not pruned") }
    catch let error as OperationError { #expect(error.code == .unknownOperation) }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await coordinator.run() }
      tasks.addTask {
        for await _ in acknowledged { break }
        _ = try await coordinator.client(group: .shared)
        await coordinator.shutdown()
      }
      while try await tasks.next() != nil {}
    }
    continuation.finish()
    #expect(try await store.read(healthy.id).committed["out"]?.rawValue == 70000)
    #expect(try await store.read(healthy.id).snapshot?.outputConsumed == true)
  }

  @Test func malformedLocalReceiptStillFailsOwnedRunInsteadOfRetiringWorker() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    let route = RecoveryRoute(id: record.id)
    let coordinator = Self.coordinator(space: space, key: key, route: route)
    try await coordinator.prepare()
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE machine_v2_operations SET record = 'malformed' WHERE id = ?", arguments: [record.id.uuidString])
    }
    do { try await coordinator.run(); Issue.record("malformed local receipt was retired") }
    catch let error as OperationError { #expect(error.code == .storeUnavailable) }
    #expect(await route.calls.isEmpty)
    await #expect(throws: OperationError.self) { try await coordinator.client(group: .shared) }
  }
}

extension MachineV2CoordinatorTests {
  @Test func lostRouteTerminalUnacknowledgedReceiptRetiresAfterLocalRetentionPrunesIt() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = Self.record()
    _ = try await store.claim(.init(scope: "dead-script", key: "terminal-unacked"), record: record)
    _ = try await store.transaction(record.id) {
      $0.snapshot = .init(operation: record.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .init(rawValue: 70000)], outputConsumed: false)
    }
    let route = RecoveryRoute(id: record.id)
    let coordinator = Self.coordinator(space: space, key: key, route: route)
    try await coordinator.prepare(); try await coordinator.tick()
    #expect(await route.calls.count == 1)
    #expect(try await store.read(record.id).snapshot?.outputConsumed == false)
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE machine_v2_retention SET expired_at = '2000-01-01T00:00:00.000Z' WHERE id = ?", arguments: [record.id.uuidString])
      try db.execute(sql: "DELETE FROM machine_v2_maintenance WHERE id = 'receipts/shared'")
    }
    _ = try await store.claim(.init(scope: "live-script", key: "trigger-retention"), record: Self.record())
    do { _ = try await store.read(record.id); Issue.record("terminal unacknowledged receipt was not pruned") }
    catch let error as OperationError { #expect(error.code == .unknownOperation) }
    try await coordinator.tick()
    await route.attach()
    try await coordinator.tick()
    #expect(await route.calls.count == 1)
    _ = try await coordinator.client(group: .shared)
    await coordinator.shutdown()
  }
}
