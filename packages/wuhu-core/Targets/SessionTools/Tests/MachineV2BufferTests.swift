#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import SpaceCore
import Synchronization
import Testing

private struct BufferedDuplexKind: OperationKind {
  typealias Input = JSONValue
  let descriptor = KindDescriptor("buffered.v1", inputSchema: [:], resultSchema: [:], inputChannels: [.init("stdin", windowBytes: 65536)], outputChannels: [.init("stdout", windowBytes: 196_608), .init("stderr", windowBytes: 196_608)])
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await channels.send(.init(data: Data(repeating: 42, count: 196_608)), to: "stdout")
    try await channels.send(.init(data: Data(repeating: 43, count: 196_608)), to: "stderr")
    while true { try await cancellation.check(); try await ContinuousClock().sleep(for: .milliseconds(10)) }
  }
}

@Suite struct MachineV2BufferTests {
  @Test func widePollsAndPendingInputUseChannelBudgetsAndFullReaderSuspends() async throws {
    let space = try Space.inMemory(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    var limits = OperationLimits(); limits.pollBytes = 98304; limits.resultBytes = 1024
    let agent = try OperationAgent(machine: "disk", kinds: [AnyOperationKind(BufferedDuplexKind())], limits: limits, authorize: { _, _ in })
    let polls = Mutex(0)
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
      if request.url.query?.contains("channel=") == true { polls.withLock { $0 += 1 } }
      return try await agent.handler(request)
    }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let id = try await client.start("disk", request: .init(kind: "buffered.v1", input: [:]), owner: .init(scope: "buffers", key: "one"))
      _ = try await client.write(id, channel: "stdin", payload: .init(data: Data(repeating: 1, count: 65536)))
      #expect(try await client.write(id, channel: "stdin", payload: .init(data: Data(repeating: 2, count: 65536))).blocked)
      for _ in 0 ..< 2 {
        async let a = client.poll(id, channel: "stdout", holdMs: 20000)
        async let b = client.poll(id, channel: "stderr", holdMs: 20000)
        let (x, y) = try await (a, b)
        #expect(x.payload?.byteCount == 98304); #expect(y.payload?.byteCount == 98304)
      }
      let retained = try await store.read(id)
      #expect(retained.pendingInputs["stdin"]?.payload.byteCount == 65536)
      #expect(retained.output.values.flatMap { $0 }.reduce(0) { $0 + $1.byteCount } == 393_216)
      let before = polls.withLock { $0 }; let answered = Mutex(false)
      let waiting = Task { defer { answered.withLock { $0 = true } }; return try await client.poll(id, channel: "stdout") }
      try await ContinuousClock().sleep(for: .milliseconds(30))
      #expect(!answered.withLock { $0 }); #expect(polls.withLock { $0 } == before)
      #expect(try await client.takeOutput(id, channel: "stdout").reduce(0) { $0 + $1.byteCount } == 196_608)
      #expect(try await waiting.value.verdict == nil)
      #expect(polls.withLock { $0 } == before + 1)
      #expect(try await store.read(id).stopReason == nil)
      _ = try await client.stop(id, reason: "testComplete")
      await agent.shutdown(); await client.shutdown()
    }
  }
}

private struct TerminalWindowKind: OperationKind {
  typealias Input = JSONValue
  let descriptor = KindDescriptor("terminal-window.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("data", windowBytes: 65536)])
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await channels.send(.init(data: Data(repeating: 42, count: 65536)), to: "data")
    return .null
  }
}

extension MachineV2BufferTests {
  @Test func terminalAcknowledgedButUntakenPayloadStillOwnsMachineBudget() async throws {
    let space = try Space.inMemory(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    var limits = OperationLimits(); limits.bufferBytes = 65536; limits.resultBytes = 1024
    let agent = try OperationAgent(machine: "disk", kinds: [AnyOperationKind(TerminalWindowKind())], limits: limits, authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init(fetch: agent.handler), store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let request = StartRequest(kind: "terminal-window.v1", input: [:])
      let first = try await client.start("disk", request: request, owner: .init(scope: "terminal-budget", key: "first"))
      _ = try await client.poll(first, channel: "data", holdMs: 20000)
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      var terminal = try await client.reconcile(first)
      while terminal.verdict == nil && ContinuousClock().now < deadline { terminal = try await client.reconcile(first) }
      #expect(terminal.verdict?.tag == .completed)
      #expect(try await client.poll(first, channel: "data", terminalAck: true).outputConsumed)
      #expect(try await store.read(first).output["data"]?.reduce(0) { $0 + $1.byteCount } == 65536)
      do {
        _ = try await client.start("disk", request: request, owner: .init(scope: "terminal-budget", key: "second"))
        Issue.record("Untaken terminal payload did not reserve machine budget")
      } catch let error as OperationError { #expect(error.code == .capacityExceeded) }
      #expect(try await store.lookup(.init(scope: "terminal-budget", key: "second")) == nil)
      #expect(try await client.takeOutput(first, channel: "data").reduce(0) { $0 + $1.byteCount } == 65536)
      _ = try await client.start("disk", request: request, owner: .init(scope: "terminal-budget", key: "second"))
      await agent.shutdown(); await client.shutdown()
    }
  }
}
