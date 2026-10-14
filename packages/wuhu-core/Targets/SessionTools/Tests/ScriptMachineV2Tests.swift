import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct ScriptMachineV2Tests {
  @Test func noRouteIsTypedAndNeverUsesV1() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.addMachine(name: "box-v2")
      let scripts = Scripts(space: space)
      let session = try await makeSession(space)
      let execution = scripts.start("""
      import { machineV2, MachineOperationError } from 'wuhu:machine'
      try { await machineV2('box-v2').describe() } catch (e) {
        result({ typed: e instanceof MachineOperationError, code: e.code, started: e.details.started })
      }
      """, session: session, lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("{\"typed\":true,\"code\":\"machineUnavailable\",\"started\":false}"))
      }
    }
  }
}

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import struct SpaceContract.GroupID
import Synchronization

extension ScriptMachineV2Tests {
  @Test func realScriptStreamsAndEarlyBreakStopsWithDurableEvidence() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machine = try await space.addMachine(name: "box-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
      let sink = try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [AnyOperationKind(ScriptStreamKind())], authorize: { _, _ in })
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: sink)
      let scripts = Scripts(space: space, machinesV2: .init(client: { _ in client }))
      let execution = scripts.start("""
      import { machineV2 } from 'wuhu:machine'
      const op = await machineV2('box-v2').start('stream.v1', {}, { key: 'stream' })
      let count = 0
      for await (const chunk of op.output('data')) { count += chunk.byteLength; break }
      result((await op.result()).tag)
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }
        group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("stopped"))
        await agent.shutdown(); group.cancelAll()
      }
      let record = try #require(try await store.lookup(.init(scope: execution.id, key: "stream")))
      #expect(record.snapshot?.verdict?.tag == .stopped)
      #expect(record.snapshot?.verdict?.reason == "outputAbandoned")
    }
  }
}

private struct ScriptStreamKind: OperationKind {
  typealias Input = JSONValue
  let descriptor = KindDescriptor("stream.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("data", windowBytes: 4, maxRecordBytes: 4)])
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    while true { try await cancellation.check(); try await channels.send(.init(data: Data([1, 2, 3, 4])), to: "data") }
  }
}

extension ScriptMachineV2Tests {
  @Test func parallelIndependentChannelsDoNotCompeteForStatePolls() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory(); let machine = try await space.addMachine(name: "duplex-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [AnyOperationKind(DualOutputKind())], authorize: { _, _ in })
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
      let scripts = Scripts(space: space, machinesV2: .init(client: { _ in client }))
      let execution = scripts.start("""
      import { machineV2 } from 'wuhu:machine'
      const op = await machineV2('duplex-v2').start('dual.v1', {})
      const drain = async name => { let count = 0; for await (const bytes of op.output(name)) count += bytes.byteLength; return count }
      const [a, b, verdict] = await Promise.all([drain('stdout'), drain('stderr'), op.result()])
      result({ counts: [a,b], tag: verdict.tag })
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }; group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("{\"counts\":[8,8],\"tag\":\"completed\"}"))
        await agent.shutdown(); group.cancelAll()
      }
    }
  }
}

private struct DualOutputKind: OperationKind {
  typealias Input = JSONValue
  let descriptor = KindDescriptor("dual.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("stdout", windowBytes: 4, maxRecordBytes: 4), .init("stderr", windowBytes: 4, maxRecordBytes: 4)])
  func run(_ input: JSONValue, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    for _ in 0 ..< 2 {
      try await channels.send(.init(data: Data([1, 2, 3, 4])), to: "stdout")
      try await channels.send(.init(data: Data([5, 6, 7, 8])), to: "stderr")
    }
    return .null
  }
}

extension ScriptMachineV2Tests {
  @Test func sequentialQuickStreamsReleaseAllAdmissionSlots() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory(); let machine = try await space.addMachine(name: "quick-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [AnyOperationKind(DualOutputKind())], authorize: { _, _ in })
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
      let scripts = Scripts(space: space, machinesV2: .init(client: { _ in client }))
      let execution = scripts.start("""
      import { machineV2 } from 'wuhu:machine'
      for (let i = 0; i < 12; i++) {
        const op = await machineV2('quick-v2').start('dual.v1', {}, { key: String(i) })
        const drain = async name => { for await (const bytes of op.output(name)) {} }
        await Promise.all([drain('stdout'), drain('stderr')])
      }
      result('all-completed')
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }; group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("all-completed"))
        await agent.shutdown(); group.cancelAll()
      }
    }
  }

  @Test func preparationRejectionsDoNotLeakDurableActiveClaims() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory(); let machine = try await space.addMachine(name: "reject-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let key = SymmetricKey(size: .bits256)
      let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
      let scripts = Scripts(space: space, machinesV2: .init(client: { _ in client }))
      let execution = scripts.start("""
      import { machineV2 } from 'wuhu:machine'
      const codes = []
      for (let i = 0; i < 12; i++) {
        try { await machineV2('reject-v2').start('grep.v1', { root: '/', pattern: 'x', dialect: 'regex', maxLineBytes: 20 }, { key: String(i) }) }
        catch(e) { codes.push(e.code) }
      }
      result(codes)
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }; group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("[" + Array(repeating: "\"unsupportedDialect\"", count: 12).joined(separator: ",") + "]"))
        await agent.shutdown(); group.cancelAll()
      }
      let records = try await space.machineV2Recovery(group: .shared, key: key)
      #expect(records.count == 12)
      #expect(records.allSatisfy { $0.record.stopReason == "startFailed" && $0.record.unknown?.code == .unknownOperation })
    }
  }
}

extension ScriptMachineV2Tests {
  @Test(arguments: ["body", "errorBody", "operation", "offset"])
  func malformedRealResponsesCreatePinnedProblems(_ damage: String) async throws {
    let space = try Space.inMemory()
    let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    let agent = try OperationAgent(machine: "disk", kinds: [AnyOperationKind(DualOutputKind())], authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
      let response = try await agent.handler(request)
      guard request.method == .post || request.url.query?.contains("channel=") == true else { return response }
      if damage == "body" || damage == "errorBody" { return .text("not-json", status: damage == "errorBody" ? .badRequest : .ok, headers: response.headers) }
      let original = try await response.body.json(OperationSnapshot.self)
      let snapshot = OperationSnapshot(operation: damage == "operation" ? UUID() : original.operation, verdict: original.verdict, terminalToken: original.terminalToken, finalOffsets: original.finalOffsets, outputConsumed: original.outputConsumed, channel: original.channel, from: original.channel == nil ? nil : Offset(rawValue: 999), through: original.through, payload: original.payload, channelEnd: original.channelEnd)
      return try .json(snapshot, headers: response.headers)
    }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
    _ = try await client.describe("disk")
    do {
      let id = try await client.start("disk", request: .init(kind: "dual.v1", input: [:]), owner: .init(scope: "malformed", key: damage))
      _ = try await client.poll(id, channel: "stdout")
      Issue.record("Malformed response accepted")
    } catch let error as OperationError { #expect(error.code == .invalidResponse) }
    let rows = try await space.query("SELECT event, error_code, status, problem_id FROM machine_v2_trace WHERE error_code = 'invalidResponse'", as: .init(actor: .anonymous, group: .shared))
    #expect(rows.rows.count == 1)
    if let row = rows.rows.first { #expect(row[0] == .text("failure")); #expect(row[2] == .integer(damage == "errorBody" ? 400 : 200)); #expect(row[3] != .null) }
    let problems = try await space.query("SELECT occurrences FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .anonymous, group: .shared))
    #expect(problems.rows == [[.integer(1)]])
    await client.shutdown()
  }
}

private final class ScriptLocalTime: Sendable {
  let value = Mutex<Duration>(.zero)
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { _ in throw CancellationError() }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

extension ScriptMachineV2Tests {
  @Test func callerDeadlineKeepsMaintenanceUntilConclusiveStopEvidence() async throws {
    let time = ScriptLocalTime(); let store = MemoryOperationStore()
    let agent = try OperationAgent(machine: "disk", kinds: [AnyOperationKind(DualOutputKind())], clock: time.clock, authorize: { _, _ in })
    let stops = Mutex(0); let terminal = Mutex(false)
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
      let response = try await agent.handler(request)
      if request.url.path.hasSuffix("/stop") {
        stops.withLock { $0 += 1 }
        let original = try await response.body.json(OperationSnapshot.self)
        let ended = terminal.withLock { $0 }
        return try .json(OperationSnapshot(operation: original.operation, verdict: ended ? .init(.stopped, reason: "callerDeadline") : nil, terminalToken: ended ? UUID() : nil, finalOffsets: [:], outputConsumed: ended), headers: response.headers)
      }
      return response
    }, clock: time.clock, store: store, abort: { _ in }, trace: { _ in })
    _ = try await client.describe("disk")
    let registry = ScriptV2Operations()
    try registry.reserve()
    let id = try await client.start("disk", request: .init(kind: "dual.v1", input: [:]), owner: .init(scope: "deadline", key: "one"), timeout: .seconds(1), onClaim: { registry.adopt($0, handle: .init(client: ScriptMachineV2Client(client: client), machine: "disk"), key: "one") })
    try await registry.settle(nil, handle: nil)
    time.advance(.seconds(1))
    await registry.maintenancePass()
    let before = stops.withLock { $0 }
    await registry.maintenancePass()
    #expect(stops.withLock { $0 } > before)
    #expect(try await store.read(id).stopReason == "callerDeadline")
    #expect(try await store.read(id).snapshot?.verdict == nil)
    terminal.withLock { $0 = true }
    await registry.maintenancePass()
    #expect(try await store.read(id).snapshot?.verdict?.tag == .stopped)
    let after = stops.withLock { $0 }
    await registry.maintenancePass()
    #expect(stops.withLock { $0 } == after)
    await registry.shutdown(); await client.shutdown()
  }

  @Test func cancellationWhileStartPostIsOutstandingStopsAdoptedClaim() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory(); let machine = try await space.addMachine(name: "cancel-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [AnyOperationKind(DualOutputKind())], authorize: { _, _ in })
      let (entered, enteredWriter) = AsyncStream<Void>.makeStream()
      let (release, releaseWriter) = AsyncStream<Void>.makeStream()
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
        let response = try await agent.handler(request)
        if request.method == .post { enteredWriter.yield(()); enteredWriter.finish(); for await _ in release {} }
        return response
      }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
      let execution = Scripts(space: space, machinesV2: .init(client: { _ in client })).start("""
      import { machineV2 } from 'wuhu:machine'
      await machineV2('cancel-v2').start('dual.v1', {}, { key: 'cancelled' })
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }; group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        for await _ in entered {}
        execution.cancelHandler()
        _ = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        releaseWriter.finish()
        await agent.shutdown(); group.cancelAll()
      }
      let record = try #require(try await store.lookup(.init(scope: execution.id, key: "cancelled")))
      #expect(record.stopReason != nil)
      #expect(record.snapshot?.verdict?.tag == .stopped || record.unknown?.code == .unknownOperation)
      let traces = try await space.query("SELECT event FROM machine_v2_trace WHERE event = 'cancelled'", as: .init(actor: .anonymous, group: .shared))
      #expect(!traces.rows.isEmpty)
      await client.shutdown()
    }
  }
}

extension ScriptMachineV2Tests {
  @Test func reusedWrappersShareReaderOwnershipWithoutStoppingTheWinner() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory(); let machine = try await space.addMachine(name: "reuse-v2")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [AnyOperationKind(DualOutputKind())], authorize: { _, _ in })
      let posts = Mutex(0)
      let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
        if request.method == .post { posts.withLock { $0 += 1 } }
        return try await agent.handler(request)
      }, store: store, abort: { _ in }, trace: try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared))
      let execution = Scripts(space: space, machinesV2: .init(client: { _ in client })).start("""
      import { machineV2 } from 'wuhu:machine'
      const m = machineV2('reuse-v2')
      const input = { value: 4294967296 }
      const op = await m.start('dual.v1', input, { key: 'same' })
      const alias = await m.start('dual.v1', input, { key: 'same' })
      const reader = op.output('stdout')
      let count = (await reader.next()).value.byteLength
      let rejected = false
      try { await alias.output('stdout').next() } catch(e) { rejected = e instanceof TypeError }
      const rest = async () => { for await (const bytes of reader) count += bytes.byteLength }
      const err = async () => { for await (const bytes of alias.output('stderr')) {} }
      await Promise.all([rest(), err()])
      result({ same: op.id === alias.id, rejected, count, tag: (await op.result()).tag })
      """, session: try await makeSession(space), lifetime: .seconds(10), tools: ToolExecutor(space: space))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }; group.addTask { await execution.run(owner: InProcessToolOwnerClient(space: space)) }
        let answer = try? await execution.answer(within: .seconds(5), onTimeout: .kill)
        #expect(answer == .result("{\"same\":true,\"rejected\":true,\"count\":8,\"tag\":\"completed\"}"))
        await agent.shutdown(); group.cancelAll()
      }
      #expect(posts.withLock { $0 } == 1)
    }
  }
}
