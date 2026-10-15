#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import Fetch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import Synchronization
import Testing

private struct EchoKind: OperationKind {
  struct Input: Decodable, Sendable { let text: String }
  let descriptor = KindDescriptor("echo.v1", inputSchema: ["type": "object"], resultSchema: ["type": "string"], deliveryPolicy: .boundedResult)
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> String { input.text }
}

private final class FakeExternal: Sendable {
  let usage = Mutex((active: 0, receipts: 0, bufferBytes: 0))
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
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      defer { group.cancelAll() }
      let description = try await client.describe("disk")
      #expect(description.kinds.map(\.name) == ["read.v1", "find.v1", "grep.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "echo.v1"])
      let echo = try await client.start("disk", request: .init(kind: "echo.v1", input: ["text": "hi"]), owner: .init(scope: "test", key: "echo"))
      var snapshot = try await client.poll(echo, holdMs: 1000)
      while snapshot.verdict == nil { snapshot = try await client.poll(echo, holdMs: 1000) }
      #expect(snapshot.verdict?.result == "hi")
      let read = try await client.start("disk", request: .init(kind: "read.v1", input: ["path": "/file"]), owner: .init(scope: "test", key: "read"))
      var bytes = Data()
      while true {
        snapshot = try await client.poll(read, channel: "data", holdMs: 10)
        for payload in try await client.takeOutput(read, channel: "data") { bytes.append(payload.data ?? Data()) }
        if snapshot.channelEnd { break }
      }
      #expect(bytes == Data("injected".utf8))
      await agent.shutdown()
    }
  }

  @Test func externalKindSharesAdmissionAndOwnsItsOperations() async throws {
    let external = FakeExternal()
    let agent = try ComputerAgent(machine: "disk", kinds: [AnyOperationKind(EchoKind())], external: external.kind)
    let description = try await agent.handler(Request(url: URL(string: base)!)).body.json(MachineDescription.self)
    #expect(description.kinds.map(\.name) == ["external.v1", "read.v1", "find.v1", "grep.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "echo.v1"])
    let id = UUID()
    #expect(try await start(agent, id, kind: "external.v1", input: [:]).body.json([String: String].self) == ["routed": "external"])
    let poll = try await agent.handler(Request(url: URL(string: base + "/operations/" + id.uuidString)!))
    #expect(try await poll.body.json([String: String].self) == ["routed": "external"])
    #expect(try await start(agent, id, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .operationExists)
    external.usage.withLock { $0.active = OperationLimits().activeOperations - 1 }
    #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).status.code == 201)
    #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .capacityExceeded)
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
    for usage in [(active: -1, receipts: 0, bufferBytes: 0), (active: 0, receipts: -1, bufferBytes: 0), (active: 0, receipts: 0, bufferBytes: -OperationLimits().bufferBytes)] {
      external.usage.withLock { $0 = usage }
      #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .supervisorUnavailable)
      #expect(try await agent.handler(Request(url: URL(string: base)!)).body.json(ErrorEnvelope.self).error.code == .supervisorUnavailable)
    }
    for usage in [(active: Int.max, receipts: 0, bufferBytes: 0), (active: 0, receipts: Int.max, bufferBytes: 0), (active: 0, receipts: 0, bufferBytes: Int.max)] {
      external.usage.withLock { $0 = usage }
      #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).body.json(ErrorEnvelope.self).error.code == .capacityExceeded)
    }
    external.usage.withLock { $0 = (0, 0, 0) }
    #expect(try await start(agent, kind: "echo.v1", input: ["text": "x"]).status.code == 201)
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
