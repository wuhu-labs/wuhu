#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import OperationClient
import OperationProtocol
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private final class AdmissionTime: Sendable {
  let value = Mutex<Duration>(.zero)
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { try await ContinuousClock().sleep(for: $0) }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private final class RecoveryBacklog: Sendable {
  struct State {
    var active = 0
    var maximum = 0
    var releases: [AsyncStream<Void>.Continuation] = []
  }

  let state = Mutex(State())
  let entered: AsyncStream<Void>
  let entrance: AsyncStream<Void>.Continuation
  init() { (entered, entrance) = AsyncStream.makeStream() }
  func fetch() async throws -> Response {
    let (stream, release) = AsyncStream<Void>.makeStream()
    state.withLock { $0.active += 1; $0.maximum = max($0.maximum, $0.active); $0.releases.append(release) }
    entrance.yield(())
    defer { state.withLock { $0.active -= 1 } }
    for await _ in stream {}
    throw OperationError(.machineUnavailable)
  }

  func release() { state.withLock { $0.releases }.forEach { $0.finish() }; entrance.finish() }
}

@Suite struct MachineV2RecoveryAdmissionTests {
  @Test func consumedTerminalReceiptsNeverEnterRecovery() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    for n in 0 ..< 51 {
      let record = Self.record(machine: "retired-\(n)")
      _ = try await store.claim(.init(scope: "done-\(n)", key: "one"), record: record)
      _ = try await store.transaction(record.id) {
        $0.snapshot = .init(operation: record.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: true)
      }
    }
    let calls = Mutex(0)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: Self.origin, fetch: { _ in
      FetchClient { _ in calls.withLock { $0 += 1 }; throw OperationError(.machineUnavailable) }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    for _ in 0 ..< 3 { try await coordinator.tick() }
    #expect(calls.withLock { $0 } == 0)
    await coordinator.shutdown()
  }

  @Test func unavailableMachineBackoffIsSharedAcrossReceiptsAndCappedAtTwoMinutes() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    for n in 0 ..< 16 {
      let record = Self.record(machine: "absent")
      _ = try await store.claim(.init(scope: "done-\(n)", key: "one"), record: record)
      _ = try await store.transaction(record.id) {
        $0.snapshot = .init(operation: record.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: false)
      }
    }
    let time = AdmissionTime(); let calls = Mutex(0)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: Self.origin, clock: time.clock, fetch: { _ in
      FetchClient { _ in calls.withLock { $0 += 1 }; throw OperationError(.machineUnavailable) }
    }, abort: { _, _ in })
    try await coordinator.prepare(); try await coordinator.tick()
    #expect(calls.withLock { $0 } == 1)
    var expected = 1
    for delay in [1, 2, 4, 8, 16, 32, 64, 120, 120] {
      time.advance(.seconds(delay) - .milliseconds(1))
      try await coordinator.tick()
      #expect(calls.withLock { $0 } == expected)
      time.advance(.milliseconds(1)); try await coordinator.tick(); expected += 1
      #expect(calls.withLock { $0 } == expected)
    }
    await coordinator.shutdown()
  }

  @Test func detachedMachineIsNotPolledUntilDescriptionProvesReattachment() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let machine = try await space.addMachine(name: "detached-recovery")
    try await space.registerMachineV2(machine.id.rawValue, group: .shared)
    try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .detached, reason: "leaving")
    let record = Self.record(machine: machine.id.rawValue)
    _ = try await store.claim(.init(scope: "dead", key: "one"), record: record)
    let time = AdmissionTime(); let attached = Mutex(false); let operationCalls = Mutex(0)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: Self.origin, clock: time.clock, fetch: { _ in
      FetchClient { request in
        if request.url.path.contains("/operations/") {
          operationCalls.withLock { $0 += 1 }
          return Self.reply(try .json(OperationSnapshot(operation: record.id, verdict: .init(.stopped, reason: "serverRestart"), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: true)), to: request)
        }
        guard attached.withLock({ $0 }) else { throw OperationError(.machineUnavailable) }
        return Self.reply(try .json(record.description), to: request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare(); try await coordinator.tick()
    time.advance(.seconds(60)); try await coordinator.tick()
    #expect(operationCalls.withLock { $0 } == 0)
    attached.withLock { $0 = true }; time.advance(.seconds(20)); try await coordinator.tick()
    time.advance(.seconds(4)); try await coordinator.tick()
    #expect(operationCalls.withLock { $0 } > 0)
    await coordinator.shutdown()
  }

  @Test(arguments: [true, false])
  func provenReattachmentClearsMaximumRecoveryBackoff(startDetached: Bool) async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let machine = try await space.addMachine(name: "reconnect-at-cap")
    try await space.registerMachineV2(machine.id.rawValue, group: .shared)
    try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: startDetached ? .detached : .lost, reason: "unavailable")
    let record = Self.record(machine: machine.id.rawValue)
    _ = try await store.claim(.init(scope: "terminal", key: "one"), record: record)
    let terminal = OperationSnapshot(operation: record.id, verdict: .init(.completed, result: .bool(true)), terminalToken: UUID(), finalOffsets: ["out": .zero], outputConsumed: false)
    _ = try await store.transaction(record.id) { $0.snapshot = terminal }
    let time = AdmissionTime(); let attached = Mutex(false); let operationCalls = Mutex(0)
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: Self.origin, clock: time.clock, fetch: { _ in
      FetchClient { request in
        guard attached.withLock({ $0 }) else { throw OperationError(.machineUnavailable) }
        if request.url.path.contains("/operations/") {
          operationCalls.withLock { $0 += 1 }
          let channel = request.url.query?.contains("channel=out") == true ? "out" : nil
          let consumed = OperationSnapshot(operation: record.id, verdict: terminal.verdict, terminalToken: terminal.terminalToken, finalOffsets: terminal.finalOffsets, outputConsumed: true, channel: channel, from: channel.map { _ in .zero }, through: channel.map { _ in .zero }, payload: channel.map { _ in .init(data: Data()) }, channelEnd: channel != nil)
          return Self.reply(try .json(consumed), to: request)
        }
        return Self.reply(try .json(record.description), to: request)
      }
    }, abort: { _, _ in })
    try await coordinator.prepare(); try await coordinator.tick()
    for delay in [1, 2, 4, 8, 16, 32, 64] {
      time.advance(.seconds(delay)); try await coordinator.tick()
    }
    #expect(try await store.read(record.id).snapshot?.outputConsumed == false)
    attached.withLock { $0 = true }; time.advance(.seconds(20)); try await coordinator.tick()
    time.advance(.seconds(1)); try await coordinator.tick()
    #expect(operationCalls.withLock { $0 } > 0)
    #expect(try await store.read(record.id).snapshot?.outputConsumed == true)
    let drainedCalls = operationCalls.withLock { $0 }
    try await coordinator.tick()
    #expect(operationCalls.withLock { $0 } == drainedCalls)
    await coordinator.shutdown()
  }

  @Test func interactiveReadSucceedsWhileRecoveryHasFortyBlockedMachines() async throws {
    let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    for n in 0 ..< 40 {
      _ = try await store.claim(.init(scope: "dead-\(n)", key: "one"), record: Self.record(machine: "blocked-\(n)"))
    }
    let folder = try ScratchFolder("interactive-recovery")
    let file = folder.url.appending(path: "note.txt")
    try Data("interactive-read".utf8).write(to: file)
    let agent = try ComputerAgent(machine: "interactive")
    let backlog = RecoveryBacklog()
    let coordinator = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: Self.origin, fetch: { _ in
      FetchClient { request in
        if request.url.path.contains("/machines/interactive") { return try await agent.handler(request) }
        return try await backlog.fetch()
      }
    }, abort: { _, _ in })
    try await coordinator.prepare()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await coordinator.tick() }
      do {
        var arrivals = 0
        for await _ in backlog.entered { arrivals += 1; if arrivals == 4 { break } }
        let client = try await coordinator.client(group: .shared)
        let result = try await client.vfs(machine: "interactive", op: .read(path: file.path), owner: .init(scope: "live", key: "read"))
        guard case let .file(_, data) = result else { Issue.record("interactive read failed: \(result)"); throw OperationError(.invalidResponse) }
        #expect(String(decoding: data.bytes, as: UTF8.self) == "interactive-read")
        #expect(backlog.state.withLock { $0.maximum } == 4)
        backlog.release(); await coordinator.shutdown(); await agent.shutdown(); tasks.cancelAll()
      } catch {
        backlog.release(); await coordinator.shutdown(); await agent.shutdown(); tasks.cancelAll(); throw error
      }
    }
  }

  private static let origin = URL(string: "https://recovery.invalid")!
  private static func record(machine: String) -> ClientRecord {
    let descriptor = KindDescriptor("query.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("out")])
    return .init(id: UUID(), correlation: UUID(), machine: machine, start: .init(kind: "query.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [descriptor]))
  }

  private static func reply(_ reply: Response, to request: Request) -> Response {
    var response = reply
    for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID"] { response.headers[.init(name)!] = request.headers[name] }
    response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
    return response
  }
}
