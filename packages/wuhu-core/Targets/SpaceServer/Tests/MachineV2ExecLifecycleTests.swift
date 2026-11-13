import DeterministicDependencies
import LoopCore
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ControlledTime
import Crypto
import Dependencies
import Fetch
import FetchTunnel
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Serve
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

private final class MachineSide: Sendable {
  let finished = Gate()
  let reasons = Mutex<[String]>([])
  func release() { finished.open() }
}

private struct ScriptedProcess: OperationKind {
  let side: MachineSide
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec

  func start(_ input: Input, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    OperationStart { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    let argv = input.argv
    func write(_ text: String) async throws { try await channels.send(.init(data: Data(text.utf8)), to: "stdout") }
    switch argv.first {
    case "exit":
      try await write(argv[1])
      return ["termination": ["tag": "exit", "code": 3]]
    case "gate":
      try await write(argv[1])
      try await cancellation.unlessStopped {
        await side.finished.wait()
        try Task.checkCancellation()
      }
      try await write(argv[2])
      return ["termination": ["tag": "exit", "code": 5]]
    default:
      try await write(argv[1])
      do {
        try await cancellation.unlessStopped {
          await side.finished.wait()
          try Task.checkCancellation()
        }
      } catch is CancellationError {
        try Task.checkCancellation()
        let reason = try #require(await cancellation.reason())
        side.reasons.withLock { $0.append(reason) }
        return ["termination": ["tag": "signal", "signal": 15]]
      }
      preconditionFailure("Held process released without a stop")
    }
  }
}

private final class Events: Sendable {
  let log = Mutex<[ExecEvent]>([])
  let firstStdoutOrEnd = Gate()
  let failure = Mutex<String?>(nil)
  func follow(_ outgoing: OutgoingExec) -> Task<Void, Never> {
    Task {
      defer { firstStdoutOrEnd.open() }
      do {
        for try await event in outgoing.events {
          log.withLock { $0.append(event) }
          switch event {
          case .output(.stdout, _, _), .exit, .failed: firstStdoutOrEnd.open()
          default: break
          }
        }
      } catch { failure.withLock { $0 = String(describing: error) } }
    }
  }

  func text(_ wanted: ExecOutputStream) -> String {
    log.withLock { log in
      log.reduce(into: "") { text, event in
        if case let .output(stream, _, data) = event, stream == wanted { text += String(decoding: data.bytes, as: UTF8.self) }
      }
    }
  }

  var stdout: String { text(.stdout) }
  var stderr: String { text(.stderr) }
  var status: MachineContract.ExitStatus? { log.withLock { $0.lazy.compactMap { if case let .exit(status) = $0 { status } else { nil } }.first } }
  var timedOut: ExecTimeout? { log.withLock { $0.lazy.compactMap { if case let .timedOut(outcome) = $0 { outcome } else { nil } }.first } }
  var truncated: Bool { log.withLock { $0.contains { if case .truncated = $0 { true } else { false } } } }
}

private func followToEnd(_ task: Task<Void, Never>) async throws {
  await withTaskCancellationHandler {
    await task.value
  } onCancel: { task.cancel() }
  try Task.checkCancellation()
}

private func waitForInitialOutput(_ events: Events, diagnostics: () -> String) async throws {
  await events.firstStdoutOrEnd.wait()
  do { try Task.checkCancellation() }
  catch {
    Issue.record("Lifecycle initial output wait was cancelled: \(diagnostics())")
    throw error
  }
}

private func eventually(diagnostics: () -> String = { "" }, _ condition: () async throws -> Bool) async throws -> Bool {
  do {
    while true {
      try Task.checkCancellation()
      if try await condition() { return true }
      await Task.yield()
    }
  } catch {
    Issue.record("Lifecycle wait ended before its condition: \(diagnostics())")
    throw error
  }
}

private func lifecycleSpace() throws -> Space {
  let space = try Space.inMemory()
  _ = space.worker
  return space
}

private struct Rig {
  let space: Space
  let machine: MachineRecord
  let side = MachineSide()
  let agent: OperationAgent
  init() async throws {
    space = try lifecycleSpace()
    machine = try await space.addMachineV2(name: "lifecycle_v2", group: .shared).machine
    agent = try OperationAgent(machine: machine.id.rawValue, kinds: [.init(ScriptedProcess(side: side))], authorize: { _, _ in })
  }

  func diagnostic(_ exec: ExecID, events: Events) -> String {
    let row = space.worker.cell(MachineCell.ID(machine.id.rawValue)).operation(exec.rawValue)
    return "events=\(events.log.withLock { $0 }), failure=\(String(describing: events.failure.withLock { $0 })), state=\(row?.state ?? "missing"), opened=\(String(describing: row?.opened)), dispatched=\(String(describing: row?.dispatched)), stop=\(String(describing: row?.stop)), diagnostic=\(String(describing: row?.diagnostic)), snapshot=\(String(describing: row?.snapshot)), flights=\(String(describing: row?.flights))"
  }
}

@Suite(.deterministicDependencies(clock: ContinuousClock()), .timeLimit(.minutes(1))) struct MachineV2ExecLifecycleTests {
  @Test(arguments: ["completed", "callerCancelled", "kill", "timeout", "outputLimit", "callerGone"])
  func everyEndingReachesTheCallerAndTheRecordAsItsOwn(_ ending: String) async throws {
    try await end(ending)
  }

  private func end(_ ending: String) async throws {
    try await withDependencies {
      $0.installTimeControl()
    } operation: {
      @Dependency(\.date) var date
      @Dependency(\.timeControl) var time
      let rig = try await Rig()
      let hub = MachineHub(space: rig.space)
      let minted = try await rig.space.reserveExec(machine: rig.machine.id, group: .shared)
      let endpoint = ChannelEndpoint()
      let command = ending == "completed" ? ["exit", "out"] : ["hold", ending == "outputLimit" ? "abcdef" : "x"]
      let outgoing = await endpoint.startExec(.init(
        id: minted.id, cwd: "/tmp", command: command, maxOutput: ending == "outputLimit" ? 3 : nil, timeout: ending == "timeout" ? 1 : 30,
      ))
      let events = Events()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await rig.agent.run() }
        defer { tasks.cancelAll() }
        try await withMachineBox(space: rig.space, hub: hub, machine: rig.machine.id, client: FetchClient { try await rig.agent.handler($0) }) {
          let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
          let caller = Task { await endpoint.run(transport) }
          let following = events.follow(outgoing)
          defer { transport.close(); caller.cancel(); following.cancel() }
          if ["callerCancelled", "kill", "callerGone", "timeout"].contains(ending) {
            try await waitForInitialOutput(events) { rig.diagnostic(minted.id, events: events) }
            try #require(events.stdout == "x", "\(rig.diagnostic(minted.id, events: events))")
          }
          switch ending {
          case "callerCancelled": await outgoing.kill()
          case "kill": try await hub.kill(minted.id)
          case "callerGone": transport.close(); caller.cancel()
          case "timeout":
            await time.advance(to: date.now.addingTimeInterval(1.001))
            try await rig.space.worker.call(MachineCell.ID(rig.machine.id.rawValue)) { try $0.wake() }
          default: break
          }
          if ending != "callerGone" {
            try await followToEnd(following)
            #expect(events.status != nil, "\(rig.diagnostic(minted.id, events: events))")
          }
          #expect(try await eventually(diagnostics: { rig.diagnostic(minted.id, events: events) }) { try await rig.space.execRecord(minted.id)?.terminal != nil })
          let terminal = try await rig.space.execRecord(minted.id)?.terminal
          switch ending {
          case "completed":
            #expect(events.stdout == "out"); #expect(events.status == .exited(code: 3)); #expect(terminal == .exited(code: 3))
            #expect(rig.side.reasons.withLock { $0 }.isEmpty)
          case "callerCancelled", "kill":
            #expect(events.status == .signaled(signal: 15)); #expect(terminal == .signaled(signal: 15))
          case "callerGone":
            #expect(terminal == .signaled(signal: 15))
          case "timeout":
            #expect(events.status == .signaled(signal: 15)); #expect(events.timedOut == .killed); #expect(terminal == .signaled(signal: 15))
          default:
            #expect(events.stdout == "abc"); #expect(events.truncated)
            #expect(events.status == .signaled(signal: 15)); #expect(terminal == .signaled(signal: 15))
          }
          if ending != "completed" {
            let reason = ending == "kill" ? "callerCancelled" : ending
            #expect(try await eventually { rig.side.reasons.withLock { $0 } == [reason] })
          }
          if ending != "timeout" { #expect(events.timedOut == nil) }
        }
        await rig.agent.shutdown()
      }
    }
  }

  @Test func aBackgroundExecOutlivesItsCallerAndTellsItsSessionHowItEnded() async throws {
    let rig = try await Rig()
    let hub = MachineHub(space: rig.space)
    _ = try await SessionToolFixture(space: rig.space)
    let session = try await rig.space.sessions.createSession(group: .shared, title: "s", kind: .agent, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    try await rig.space.sessions.markInterrupted(session)
    let minted = try await rig.space.reserveExec(machine: rig.machine.id, caller: session.rawValue, toolCall: ToolCallID(rawValue: "call"))
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "a", "b"]))
    let events = Events()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll(); rig.side.release() }
      try await withMachineBox(space: rig.space, hub: hub, machine: rig.machine.id, client: FetchClient { try await rig.agent.handler($0) }) {
        let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
        let caller = Task { await endpoint.run(transport) }
        let following = events.follow(outgoing)
        defer { transport.close(); caller.cancel(); following.cancel() }
        try await waitForInitialOutput(events) { rig.diagnostic(minted.id, events: events) }
        try #require(events.stdout == "a", "\(rig.diagnostic(minted.id, events: events))")
        try await rig.space.worker.call(MachineCell.ID(rig.machine.id.rawValue)) { try $0.background(minted.id.rawValue) }
        transport.close(); caller.cancel(); following.cancel()
        #expect(try await rig.space.execRecord(minted.id)?.terminal == nil)
        rig.side.release()
        #expect(try await eventually(diagnostics: { rig.diagnostic(minted.id, events: events) }) { try await rig.space.execRecord(minted.id)?.terminal == .exited(code: 5) })
        #expect(try await eventually {
          try await rig.space.sessions.deliverMail(session)
          return try await rig.space.sessions.undrainedInputs(session).contains { entry in
            guard case let .notification(n) = entry.input else { return false }
            return n.content.text.hasPrefix("exec.\(minted.id.rawValue) ended") && n.content.text.hasSuffix("ab")
          }
        })
      }
      await rig.agent.shutdown()
    }
  }

  @Test func deleteEndsAnOpenExecCallerAndDropsDurableOperationState() async throws {
    let rig = try await Rig()
    let hub = MachineHub(space: rig.space)
    let handler = SpaceServer.configuredHandler(space: rig.space, hub: hub, devPerson: try await rig.space.ensureDevPerson())
    let minted = try await rig.space.reserveExec(machine: rig.machine.id)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "a", "b"]))
    let events = Events()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll(); rig.side.release() }
      try await withMachineBox(space: rig.space, hub: hub, machine: rig.machine.id, client: FetchClient { try await rig.agent.handler($0) }) {
        let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
        let caller = Task { await endpoint.run(transport) }
        let following = events.follow(outgoing)
        defer { transport.close(); caller.cancel(); following.cancel() }
        try await waitForInitialOutput(events) { rig.diagnostic(minted.id, events: events) }
        try #require(events.stdout == "a", "\(rig.diagnostic(minted.id, events: events))")
        let request = Request(url: URL(string: "https://space.test/v1/machine/" + rig.machine.id.rawValue)!, method: .delete)
        guard case let .response(response) = try await handler(request) else { Issue.record("delete upgraded"); return }
        #expect(response.status == .ok)
        try await followToEnd(following)
        #expect(events.status == .exited(code: 1))
        #expect(try await rig.space.execRecord(minted.id) == nil)
      }
      await rig.agent.shutdown()
    }
  }
}

private final class Link: Sendable {
  let first: TunnelTransport
  let second: TunnelTransport

  init() {
    let (toFirst, intoFirst) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (toSecond, intoSecond) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let readFirst = Reader(toFirst), readSecond = Reader(toSecond)
    let abort: @Sendable () -> Void = { intoFirst.finish(); intoSecond.finish() }
    first = TunnelTransport(receive: { try await readFirst.next() }, send: { intoSecond.yield($0) }, abort: abort)
    second = TunnelTransport(receive: { try await readSecond.next() }, send: { intoFirst.yield($0) }, abort: abort)
  }
}

private actor Reader {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    var iterator = self.iterator
    let result = try await iterator.next(isolation: self)
    self.iterator = iterator
    return result
  }
}

extension MachineV2ExecLifecycleTests {
  /// Audit 1: forty execs at once through a real tunnel. A machine that advertises the full tunnel runs them all; one that does
  /// not (32 streams) runs the ones that fit and refuses the rest with a typed capacity error at their start. None hangs.
  @Test(arguments: [MachineV2Connect.tunnelStreams, TunnelLimits().streams])
  func fortyExecsThroughARealTunnel(streams: Int) async throws {
    try await withLiveDate { try await runFortyExecs(streams: streams) }
  }

  private func runFortyExecs(streams: Int) async throws {
    let space = try lifecycleSpace()
    let signing = Curve25519.Signing.PrivateKey()
    let machine = try await space.enrollMachineV2(name: "tunnel_v2", group: .shared, pubkey: signing.pubkeyLabel).machine
    let side = MachineSide()
    let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [.init(ScriptedProcess(side: side))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let link = Link()
    let count = 40
    let credential = MachineHub.Credential(pubkey: signing.pubkeyLabel, machines: [machine.id.rawValue])
    let boxLink = try #require(await hub.boxLink(credential, streams: streams))
    let phase = Mutex("starting tunnel")
    let tracked = Mutex<[ExecID: Events]>([:])
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await agent.run() }
        tasks.addTask { await hub.run(.init(pubkey: signing.pubkeyLabel, machines: [machine.id.rawValue]), transport: link.second, boxLink: boxLink, streams: streams) }
        tasks.addTask { try await Tunnel.serve(over: link.first, limits: .init(streams: streams), handler: agent.handler) }
        defer { tasks.cancelAll(); side.release() }
        #expect(try await eventually { try await space.machineDescription(machine.id) != nil && space.worker.cell(MachineCell.ID(machine.id.rawValue)).box?.opening.streams == streams })
        var execs: [(id: ExecID, endpoint: ChannelEndpoint, events: Events, follow: Task<Void, Never>, caller: Task<Void, Never>)] = []
        for index in 0 ..< count {
          phase.withLock { $0 = "opening exec \(index)" }
          let minted = try await space.reserveExec(machine: machine.id, group: .shared)
          let endpoint = ChannelEndpoint()
          let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "a\(index)", "b\(index)"], timeout: 60))
          let events = Events()
          tracked.withLock { $0[minted.id] = events }
          let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
          execs.append((minted.id, endpoint, events, events.follow(outgoing), Task { await endpoint.run(transport) }))
        }
        defer { for exec in execs { exec.caller.cancel(); exec.follow.cancel() } }
        for (index, exec) in execs.enumerated() {
          phase.withLock { $0 = "initial output or refusal for exec \(index)" }
          try await waitForInitialOutput(exec.events) {
            let row = space.worker.cell(MachineCell.ID(machine.id.rawValue)).operation(exec.id.rawValue)
            return "exec \(index): events=\(exec.events.log.withLock { $0 }), row=\(String(describing: row))"
          }
          try #require(exec.events.stdout == "a\(index)" || exec.events.status != nil, "exec \(index): \(exec.events.log.withLock { $0 })")
        }
        side.release()
        for (index, exec) in execs.enumerated() {
          phase.withLock { $0 = "caller completion for exec \(index)" }
          try await followToEnd(exec.follow)
        }
        var ran = 0
        for (index, exec) in execs.enumerated() {
          if exec.events.status == .exited(code: 5) {
            #expect(exec.events.stdout == "a\(index)b\(index)")
            ran += 1
          } else {
            #expect(exec.events.status == .exited(code: 1))
            #expect(exec.events.stderr.hasPrefix("capacityExceeded: "), "\(exec.events.stderr)")
          }
        }
        // Each exec holds one control and two output lanes; describes keep their own.
        #expect(ran == min(count, (streams - 2) / 3))
        phase.withLock { $0 = "agent shutdown" }
        await agent.shutdown()
        phase.withLock { $0 = "joining tunnel taskgroup" }
      }
    } onCancel: {
      let records = tracked.withLock { $0 }.sorted { $0.key.rawValue < $1.key.rawValue }.map { exec, events in
        let row = space.worker.cell(MachineCell.ID(machine.id.rawValue)).operation(exec.rawValue)
        return "\(exec.rawValue): events=\(events.log.withLock { $0 }), failure=\(String(describing: events.failure.withLock { $0 })), row=\(String(describing: row))"
      }.joined(separator: "\n")
      Issue.record("forty execs cancelled: streams=\(streams), phase=\(phase.withLock { $0 })\n\(records)")
      side.release(); link.first.abort(); link.second.abort(); boxLink.close()
    }
    try await space.close()
  }

  /// A frame the cell cannot take closes the caller's stream, and the exec ends with it instead of running on with nobody to hear it.
  @Test func aStreamClosedForABadFrameStopsItsExec() async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "bad-frame", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"])
      let stream = try await f.running(exec)
      stream.send(.consumed(1_000_000))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.stop == "callerGone" }
      try await f.wait { f.count(.operation(exec.operation, .stop)) == 1 }
    }
  }
}
