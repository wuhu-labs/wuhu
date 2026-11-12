import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Tracing

@Suite(.deterministicDependencies) struct BoxLinkTests {
  @Test func fileStartUsesSuppliedRequestWithoutExecPreparation() async throws {
    let operation = UUID()
    let start = StartRequest(kind: "read.v1", input: ["path": "/file"], caller: .init(session: "session", title: "title", group: "group"))
    let answer = try await exchange(.startFile(operation, start), buffers: MachineBuffers(worker: "worker")) { request in
      #expect(request.method == .post)
      #expect(request.url.path.hasSuffix("/operations/\(operation.uuidString)"))
      let sent = try await request.json(StartRequest.self)
      #expect(sent.kind == start.kind)
      #expect(sent.input == start.input)
      #expect(sent.caller == start.caller)
      return try Response.json(self.snapshot(operation))
    }
    guard case let .snapshot(result) = answer else { Issue.record("Expected file start snapshot"); return }
    #expect(result.snapshot.operation == operation)
    #expect(result.snapshot.payload == nil)
    #expect(result.output == nil)
    #expect(result.tail.isEmpty)
  }

  @Test(arguments: [false, true])
  func fileInputPreservesChannelPayloadAndOffset(records: Bool) async throws {
    let operation = UUID(), buffers = MachineBuffers(worker: "worker")
    let payload = records ? ChannelPayload(records: [["commit": true]]) : ChannelPayload(data: Data("file bytes".utf8))
    let channel = records ? "commit" : "data"
    let pointer = try #require(buffers.put(payload: payload, operation: operation, channel: channel, from: 9))
    let answer = try await exchange(.fileInput(operation, pointer, end: true), buffers: buffers) { request in
      #expect(request.method == .put)
      #expect(request.url.path.hasSuffix("/inputs/\(channel)"))
      let sent = try await request.json(WriteRequest.self)
      #expect(sent.offset.rawValue == 9)
      #expect(sent.payload == payload)
      #expect(sent.end)
      return try Response.json(WriteReceipt(acceptedThrough: .init(rawValue: pointer.through), end: true, blocked: false))
    }
    guard case let .input(receipt) = answer else { Issue.record("Expected file input receipt"); return }
    #expect(receipt.acceptedThrough.rawValue == pointer.through)
    #expect(receipt.end)
  }

  @Test(arguments: ["data", "entries", "stdout", "stderr"])
  func outputUsesOnePayloadCacheAndOnlyExecHasTail(channel: String) async throws {
    let operation = UUID(), buffers = MachineBuffers(worker: "worker")
    let payload = channel == "entries" ? ChannelPayload(records: [.string(String(repeating: "x", count: 65534))]) : ChannelPayload(data: Data(repeating: 7, count: 65536))
    #expect(payload.byteCount == 65536)
    let answer = try await exchange(.poll(operation, channel: channel, after: 13, holdMs: 0, terminal: nil, limit: 65536), buffers: buffers) { _ in
      try Response.json(self.snapshot(operation, channel: channel, payload: payload, from: 13))
    }
    guard case let .snapshot(result) = answer else { Issue.record("Expected output snapshot"); return }
    let pointer = try #require(result.output)
    #expect(pointer.channel == channel)
    #expect(pointer.from == 13)
    #expect(pointer.through == 13 + UInt64(payload.count))
    #expect(buffers.payload(pointer) == payload)
    #expect(result.snapshot.payload == nil)
    #expect(result.tail == (["stdout", "stderr"].contains(channel) ? Data(repeating: 7, count: 51200) : Data()))
  }

  @Test func rejectsInvalidSpanAndOversizedRecordPayload() async throws {
    let operation = UUID()
    for (payload, from, through) in [
      (ChannelPayload(records: [[:]]), UInt64(5), UInt64(7)),
      (ChannelPayload(data: Data([1])), UInt64(5), UInt64(4)),
      (ChannelPayload(records: [.string(String(repeating: "x", count: 65535))]), UInt64(5), UInt64(6)),
    ] {
      let answer = try await exchange(.poll(operation, channel: "entries", after: from, holdMs: 0, terminal: nil, limit: 65536), buffers: MachineBuffers(worker: "worker")) { _ in
        try Response.json(OperationSnapshot(operation: operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: "entries", from: .init(rawValue: from), through: .init(rawValue: through), payload: payload))
      }
      guard case let .box(error) = answer else { Issue.record("Expected invalid response refusal"); continue }
      #expect(error.code == .invalidResponse)
    }
  }

  @Test(arguments: ["poll", "input", "fileInput", "describe", "stop"])
  func dispatchedExchangesDoNotReauthorizeAttachment(kind: String) async throws {
    let operation = UUID(), buffers = MachineBuffers(worker: "worker")
    let pointer = try #require(buffers.put(payload: .init(data: Data([1])), operation: operation, channel: "data", from: 0))
    let request: BoxExchange
    switch kind {
    case "poll": request = .poll(operation, channel: nil, after: 0, holdMs: 0, terminal: nil, limit: 1)
    case "input": request = .input(operation, pointer, end: true)
    case "fileInput": request = .fileInput(operation, pointer, end: true)
    case "describe": request = .describe
    default: request = .stop(operation, "callerCancelled")
    }
    let dispatched = Mutex(0)
    let answer = try await exchange(request, buffers: buffers, authorizeStart: {
      Issue.record("Already-dispatched work reauthorized the attachment")
      throw OperationError(.machineNotAuthorized)
    }) { _ in
      dispatched.withLock { $0 += 1 }
      switch request {
      case .input, .fileInput: return try Response.json(WriteReceipt(acceptedThrough: .init(rawValue: 1), end: true, blocked: false))
      case .describe: return try Response.json(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))
      default: return try Response.json(self.snapshot(operation))
      }
    }
    if case .preparation = answer { Issue.record("Existing exchange was refused at START authorization") }
    #expect(dispatched.withLock { $0 } == 1)
  }

  @Test func cancellationDuringExecPreparationNeverDispatchesAStart() async throws {
    let space = try Space.inMemory()
    let machine = try await space.addMachineV2(name: "preparing").machine.id
    let record = try await space.reserveExec(machine: machine)
    let exec = try #require(try await space.execRequest(record.id))
    let entered = Gate(), resume = Gate()
    let dispatched = Mutex(0)
    let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
    let box = try #require(BoxLink(worker: space.worker, machine: machine.rawValue, pubkey: pubkey, connection: UUID(), streams: 32, buffers: space.machineBuffers) { _ in
      entered.open()
      await resume.wait()
      try Task.checkCancellation()
      return StartRequest(kind: "exec.v1", input: [:])
    })
    let link = MachineLink(origin: URL(string: "https://box.test")!, fetch: FetchClient { _ in
      dispatched.withLock { $0 += 1 }
      return Response(status: .internalServerError)
    }, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
    let preparing = Task { await box.exchange(.start(exec), link: link) }
    defer { preparing.cancel(); resume.open(); box.close() }
    await entered.wait()
    preparing.cancel()
    resume.open()
    let answer = await preparing.value
    guard case .preparation = answer else { Issue.record("Cancelled preparation did not end before dispatch"); return }
    #expect(dispatched.withLock { $0 } == 0)
    box.close()
    try await space.close()
  }

  private func snapshot(_ operation: UUID, channel: String? = nil, payload: ChannelPayload? = nil, from: UInt64 = 0) -> OperationSnapshot {
    OperationSnapshot(operation: operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: channel, from: channel.map { _ in .init(rawValue: from) }, through: channel.map { _ in .init(rawValue: from + UInt64(payload!.count)) }, payload: payload)
  }

  private func exchange(_ exchange: BoxExchange, buffers: MachineBuffers, authorizeStart: @escaping @Sendable () async throws -> Void = {}, handle: @escaping @Sendable (Request) async throws -> Response) async throws -> BoxAnswer {
    let space = try Space.inMemory()
    let machine = try await space.addMachineV2(name: "box").machine.id.rawValue
    let pubkey = try await seedBoxKey(space: space, machine: machine)
    let candidate = BoxLink(worker: space.worker, machine: machine, pubkey: pubkey, connection: UUID(), streams: 32, buffers: buffers, authorizeStart: authorizeStart, prepare: { _ in
      Issue.record("File requests must not prepare exec secrets")
      return StartRequest(kind: "exec.v1", input: [:])
    })
    let box = try #require(candidate)
    let fetch = FetchClient { request in
      var response = try await handle(request)
      response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
      response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
      response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
      return response
    }
    let link = MachineLink(origin: URL(string: "https://box.test")!, fetch: fetch, clock: .continuous, ids: { UUID() }, tracer: NoOpTracer())
    let answer = await box.exchange(exchange, link: link)
    box.close()
    try await space.close()
    return answer
  }
}
