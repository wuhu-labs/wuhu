#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import Scratch
import Synchronization
import Testing

private struct EchoKind: OperationKind {
  struct Input: Decodable, Sendable { let text: String }
  let descriptor = KindDescriptor("echo.v1", inputSchema: ["type": "object"], resultSchema: ["type": "string"], deliveryPolicy: .boundedResult)
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> String { input.text }
}

private final class FakeExternal: Sendable {
  let usage = Mutex(ExternalUsage())
  let owned = Mutex<Set<UUID>>([])
  let left = Mutex(false)
  var kind: ExternalKind { kind() }
  func kind(descriptor: KindDescriptor = KindDescriptor("external.v1", inputSchema: ["type": "object"], resultSchema: ["type": "object"]), reservation: Int = 1024) -> ExternalKind {
    ExternalKind(
      descriptor: descriptor,
      reservation: reservation,
      handler: { request in
        let id = UUID(uuidString: request.url.lastPathComponent)!
        self.owned.withLock { _ = $0.insert(id) }
        return try .json(["routed": "external"], status: .created)
      },
      usage: { self.usage.withLock { $0 } },
      owns: { id in self.owned.withLock { $0.contains(id) } },
      leave: { self.left.withLock { $0 = true } },
      departure: { .drained },
    )
  }
}

@Suite struct ComputerAgentTests {
  let base = "https://agent/machine/v2/machines/disk"

  func start(_ agent: ComputerAgent, _ id: UUID = UUID(), kind: String, input: JSONValue) async throws -> Response {
    try await agent.handler(Request(url: URL(string: base + "/operations/" + id.uuidString)!, method: .post, body: .json(StartRequest(kind: kind, input: input))))
  }

  @Test func extraKindsAndInjectedFilesShareOneMachine() async throws {
    let files = FakeFiles(data: Data("injected".utf8))
    let agent = try ComputerAgent(machine: "disk", files: files.system, kinds: [AnyOperationKind(EchoKind())])
    let operations = try machineOperations(agent.handler)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      defer { group.cancelAll() }
      let description = try await operations.describe("disk")
      #expect(description.kinds.map(\.name) == ["read.v1", "search.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "echo.v1"])
      let echo = try await operations.open(.init(scope: "test", key: "echo"), machine: "disk", start: .init(kind: "echo.v1", input: ["text": "hi"]))
      #expect(try await echo.drain().end.verdict?.result == "hi")
      let read = try await operations.open(.init(scope: "test", key: "read"), machine: "disk", start: .init(kind: "read.v1", input: ["path": "/file"]))
      #expect(try await read.drain().data == Data("injected".utf8))
      await operations.shutdown(); await agent.shutdown()
    }
  }

  @Test func externalKindSharesAdmissionAndOwnsItsOperations() async throws {
    let external = FakeExternal()
    let agent = try ComputerAgent(machine: "disk", kinds: [AnyOperationKind(EchoKind())], external: external.kind)
    let description = try await agent.handler(Request(url: URL(string: base)!)).body.json(MachineDescription.self)
    #expect(description.kinds.map(\.name) == ["external.v1", "read.v1", "search.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "echo.v1"])
    let id = UUID()
    #expect(try await start(agent, id, kind: "external.v1", input: [:]).body.json([String: String].self) == ["routed": "external"])
    let poll = try await agent.handler(Request(url: URL(string: base + "/operations/" + id.uuidString)!))
    #expect(try await poll.body.json([String: String].self) == ["routed": "external"])
    #expect(try await start(agent, id, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .operationExists)
    external.usage.withLock { $0.receipts = OperationLimits().receipts - 1 }
    #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).status.code == 201)
    let refusal = try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error
    #expect(refusal.code == .capacityExceeded)
    #expect(refusal.message.hasPrefix("receipts "))
    #expect(try await start(agent, kind: "missing.v1", input: [:]).body.json(ErrorEnvelope.self).error.code == .unknownKind)
    await agent.shutdown()
  }

  @Test func kindNamesAreUniqueAcrossBackends() throws {
    let external = FakeExternal().kind
    let clash = ExternalKind(descriptor: ComputerKindSchemas.read, reservation: 0, handler: external.handler, usage: external.usage, owns: external.owns, leave: external.leave, departure: external.departure)
    #expect(throws: OperationError.self) { try ComputerAgent(machine: "disk", external: clash) }
    #expect(throws: OperationError.self) { try ComputerAgent(machine: "disk", kinds: [AnyOperationKind(EchoKind()), AnyOperationKind(EchoKind())]) }
  }

  @Test func externalDescriptorAndReservationAreValidatedLikeInProcessKinds() throws {
    let external = FakeExternal()
    let schema: JSONValue = ["type": "object"]
    #expect(throws: Never.self) { try ComputerAgent(machine: "disk", external: external.kind(reservation: 0)) }
    #expect(throws: Never.self) { try ComputerAgent(machine: "disk", external: external.kind(reservation: OperationLimits().bufferBytes)) }
    for reservation in [-1, OperationLimits().bufferBytes + 1, Int.min, Int.max] {
      #expect(throws: OperationError.self) { try ComputerAgent(machine: "disk", external: external.kind(reservation: reservation)) }
    }
    let invalid = [
      KindDescriptor("", inputSchema: schema, resultSchema: schema),
      KindDescriptor("external.v1", inputSchema: schema, resultSchema: schema, schemaDialect: "draft-07"),
      KindDescriptor("external.v1", inputSchema: schema, resultSchema: schema, outputChannels: [ChannelDescriptor("out", windowBytes: 0)]),
      KindDescriptor("external.v1", inputSchema: schema, resultSchema: schema, outputChannels: [ChannelDescriptor("out", windowBytes: OperationLimits().bufferBytes + 1)]),
      KindDescriptor("external.v1", inputSchema: schema, resultSchema: schema, outputChannels: [ChannelDescriptor("out"), ChannelDescriptor("out")]),
      KindDescriptor("external.v1", inputSchema: schema, resultSchema: schema, outputChannels: [ChannelDescriptor("out")], deliveryPolicy: .boundedResult),
    ]
    for descriptor in invalid {
      #expect(throws: OperationError.self) { try ComputerAgent(machine: "disk", external: external.kind(descriptor: descriptor)) }
    }
  }

  @Test func externalUsageMustBeNonnegativeAndCannotOverflowTheBudget() async throws {
    let external = FakeExternal()
    let agent = try ComputerAgent(machine: "disk", kinds: [AnyOperationKind(EchoKind())], external: external.kind)
    for usage in [ExternalUsage(receipts: -1), ExternalUsage(bufferBytes: -OperationLimits().bufferBytes), ExternalUsage(operations: [UUID(): -1])] {
      external.usage.withLock { $0 = usage }
      #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .supervisorUnavailable)
      #expect(try await agent.handler(Request(url: URL(string: base)!)).body.json(ErrorEnvelope.self).error.code == .supervisorUnavailable)
    }
    for usage in [ExternalUsage(receipts: Int.max), ExternalUsage(bufferBytes: Int.max), ExternalUsage(operations: [UUID(): Int.max, UUID(): Int.max])] {
      external.usage.withLock { $0 = usage }
      #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .capacityExceeded)
    }
    external.usage.withLock { $0 = ExternalUsage() }
    #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).status.code == 201)
    await agent.shutdown()
  }

  /// Concurrent starts see each other's reservations, and a start the backend already routes is charged once.
  @Test func concurrentExternalStartsShareOneBudget() async throws {
    let reservation = OperationLimits().bufferBytes * 2 / 5
    let routed = Mutex<Set<UUID>>([])
    let held = Mutex(true)
    let descriptor = KindDescriptor("external.v1", inputSchema: ["type": "object"], resultSchema: ["type": "object"])
    let external = ExternalKind(
      descriptor: descriptor, reservation: reservation,
      handler: { request in
        routed.withLock { _ = $0.insert(UUID(uuidString: request.url.lastPathComponent)!) }
        while held.withLock({ $0 }) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
        return try .json(["routed": "external"], status: .created)
      },
      usage: { ExternalUsage(operations: Dictionary(uniqueKeysWithValues: routed.withLock { $0 }.map { ($0, reservation) })) },
      owns: { id in routed.withLock { $0.contains(id) } },
      leave: {}, departure: { .drained },
    )
    let agent = try ComputerAgent(machine: "disk", external: external)
    let first = Task { try await start(agent, kind: "external.v1", input: [:]) }
    while routed.withLock({ $0.isEmpty }) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    // The first is both pending and routed: charged once, so the second fits; a third does not.
    let second = Task { try await start(agent, kind: "external.v1", input: [:]) }
    while routed.withLock({ $0.count < 2 }) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    let third = try await start(agent, kind: "external.v1", input: [:]).body.json(ErrorEnvelope.self).error
    #expect(third.code == .capacityExceeded)
    #expect(third.message.hasPrefix("bufferBytes "))
    held.withLock { $0 = false }
    #expect(try await first.value.status.code == 201)
    #expect(try await second.value.status.code == 201)
    await agent.shutdown()
  }

  /// Starts that arrive while the usage probe is parked are each checked after it, against the starts already admitted: the
  /// ones that fit are admitted, and only the one past the budget is refused.
  @Test func startsDuringASlowUsageProbeAreRefusedOnlyPastTheBudget() async throws {
    let reservation = OperationLimits().bufferBytes * 2 / 5
    let routed = Mutex<Set<UUID>>([])
    let parked = Mutex(0)
    let gate = Mutex(true)
    let descriptor = KindDescriptor("external.v1", inputSchema: ["type": "object"], resultSchema: ["type": "object"])
    let external = ExternalKind(
      descriptor: descriptor, reservation: reservation,
      handler: { request in
        routed.withLock { _ = $0.insert(UUID(uuidString: request.url.lastPathComponent)!) }
        return try .json(["routed": "external"], status: .created)
      },
      usage: {
        parked.withLock { $0 += 1 }
        while gate.withLock({ $0 }) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
        return ExternalUsage(operations: Dictionary(uniqueKeysWithValues: routed.withLock { $0 }.map { ($0, reservation) }))
      },
      owns: { id in routed.withLock { $0.contains(id) } },
      leave: {}, departure: { .drained },
    )
    let agent = try ComputerAgent(machine: "disk", external: external)
    let starts = (0 ..< 3).map { _ in Task { try await start(agent, kind: "external.v1", input: [:]) } }
    while parked.withLock({ $0 }) < 3 { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    gate.withLock { $0 = false }
    var admitted = 0
    for start in starts {
      let response = try await start.value
      if response.status.code == 201 { admitted += 1; continue }
      let refusal = try await response.body.json(ErrorEnvelope.self).error
      #expect(refusal.code == .capacityExceeded)
      #expect(refusal.message.hasPrefix("bufferBytes "))
    }
    #expect(admitted == 2)
    #expect(routed.withLock { $0.count } == 2)
    await agent.shutdown()
  }

  @Test func inProcessLeaveDrainsExternalAndWaitsForServerAcknowledgement() async throws {
    let external = FakeExternal()
    let agent = try ComputerAgent(machine: "disk", external: external.kind)
    let leave = Task { try await agent.leave() }
    defer { leave.cancel() }
    while !external.left.withLock({ $0 }) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    #expect(try await agent.handler(Request(url: URL(string: base)!)).body.json(ErrorEnvelope.self).error.code == .leaving)
    #expect(!(await agent.leaveAcknowledged))
    #expect(try await agent.handler(Request(url: URL(string: base + "?leaveAck=true")!)).body.json(ErrorEnvelope.self).error.code == .leaving)
    try await leave.value
    #expect(await agent.leaveAcknowledged)
    #expect(try await start(agent, kind: "external.v1", input: [:]).body.json(ErrorEnvelope.self).error.code == .leaving)
  }
}

extension ComputerAgentTests {
  @Test func auditSeesEachAdmittedStartWithItsCallerOnce() async throws {
    let external = FakeExternal()
    let seen = Mutex<[AdmittedStart]>([])
    let agent = try ComputerAgent(machine: "disk", kinds: [AnyOperationKind(EchoKind())], external: external.kind, audit: { start in seen.withLock { $0.append(start) } })
    let caller = StartRequest.Caller(session: "s1", title: "Coder", group: "shared")
    let echo = UUID(); let outside = UUID()
    func post(_ id: UUID, _ request: StartRequest) async throws -> Response {
      try await agent.handler(Request(url: URL(string: base + "/operations/" + id.uuidString)!, method: .post, body: .json(request)))
    }
    #expect(try await post(echo, .init(kind: "echo.v1", input: ["text": "x"], caller: caller)).status.code == 201)
    #expect(try await post(outside, .init(kind: "external.v1", input: [:])).status.code == 201)
    #expect(try await post(echo, .init(kind: "echo.v1", input: ["text": "x"], caller: caller)).status.code == 409)
    #expect(try await post(UUID(), .init(kind: "missing.v1", input: [:], caller: caller)).status.code == 404)
    let starts = seen.withLock { $0 }
    #expect(starts.map(\.operation) == [echo, outside])
    #expect(starts.map(\.kind) == ["echo.v1", "external.v1"])
    #expect(starts.first?.input == ["text": "x"])
    #expect(starts.map(\.caller) == [caller, nil])
    await agent.shutdown()
  }
}

extension ComputerAgentTests {
  @Test func anAbandonedDiskEffectHoldsAReceiptUntilItEnds() async throws {
    let folder = try ScratchFolder("computer-agent-abandoned-effect")
    let file = folder.url.appending(path: "stuck.txt")
    try Data("needle\n".utf8).write(to: file)
    let disk = FileOperationTests.StalledDisk(file.path)
    defer { disk.release() }
    let external = FakeExternal()
    let agent = try ComputerAgent(machine: "disk", files: disk.files, kinds: [AnyOperationKind(EchoKind())], external: external.kind)
    // The driver sends the terminal acknowledgement after the verdict; the agent releases the stopped operation on the last one.
    let (released, releasedNow) = AsyncStream<Void>.makeStream()
    let operations = try machineOperations { request in
      let response = try await agent.handler(request)
      if request.url.query?.contains("terminalAck") == true, await !agent.runtime.hasRetainedOperations() { releasedNow.yield() }
      return response
    }
    func usedReceipts() async throws -> Int? {
      let refusal = try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error
      switch refusal.details?.object?["used"] {
      case let .integer(used)?: return used
      case let .number(used)?: return Int(used)
      default: return nil
      }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      defer { group.cancelAll() }
      _ = try await operations.describe("disk")
      let query = SearchQuery(mode: .grep, pattern: "needle", root: folder.url.path, scope: "test")
      let operation = try await operations.open(.init(scope: "test", key: "abandoned"), machine: "disk", start: .init(kind: "search.v1", input: json(query)))
      for await _ in disk.entered {}
      try await operation.stop("testStop")
      _ = try await operation.drain()
      for await _ in released { break }
      external.usage.withLock { $0.receipts = OperationLimits().receipts }
      let hung = try #require(try await usedReceipts())
      disk.release()
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      var used = hung
      while used == hung, ContinuousClock().now < deadline { used = try #require(try await usedReceipts()) }
      #expect(used == hung - 1)
      await operations.shutdown(); await agent.shutdown()
    }
  }
}
