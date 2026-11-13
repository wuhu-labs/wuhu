import Clocks
import ControlledTime
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import JSONValue
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineChannel
import MachineContract
import MainHub
import OperationProtocol
import OperationRuntime
import Serve
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// A script that mints one exec and attaches to it, under the token its run was given.
private final class Spawning: Sendable {
  let tokens = Mutex<[String]>([])
  let spawn: @Sendable (_ script: String) async throws -> Void

  init(spawn: @escaping @Sendable (_ script: String) async throws -> Void) { self.spawn = spawn }

  func run(token: String, script: String) async throws {
    tokens.withLock { $0.append(token) }
    try await spawn(script)
  }
}

private final class FiringProcessSide: Sendable {
  let stopped = Gate()
  let release = Gate()
  let reason = Mutex<String?>(nil)
}

private struct FiringProcess: OperationKind {
  let side: FiringProcessSide
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec

  func start(_ input: Input, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    OperationStart { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await channels.send(.init(data: Data("ready\n".utf8)), to: "stdout")
    @Dependency(\.continuousClock) var clock
    while await cancellation.reason() == nil { try await clock.sleep(for: .milliseconds(2)) }
    let reason = await cancellation.reason()
    side.reason.withLock { $0 = reason }
    side.stopped.open()
    await side.release.wait()
    return ["termination": ["tag": "signal", "signal": 15]]
  }
}

enum SessionlessEnd: Sendable, CustomTestStringConvertible {
  case firingCancelled, terminalCancelled, terminalReturned
  var testDescription: String { "\(self)" }
}

@Suite(.deterministicDependencies(clock: ContinuousClock())) struct SessionlessExecReleaseTests {
  @Test(arguments: [SessionlessEnd.firingCancelled, .terminalCancelled, .terminalReturned])
  func aRunsEndRevokesItsTokenAndKillsTheProcessItsScriptStarted(_ end: SessionlessEnd) async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: VirtualClock())
    let (machineID, _) = try await addMachine(server)
    let tokens = try await testTokens(space: space, spaceURL: "http://main")
    let observer = Observer(group: .shared, name: "nightly", firing: "f1")
    let firing = handlerScriptID(UUID())
    let account = AccountID(rawValue: "ac_alice001")
    let terminal = TerminalRun(id: "terminal-1", persona: "nightly", account: account, group: .shared)
    let (script, caller, leg, sessionless): (String, String, ExecLeg, SessionlessScript) = switch end {
    case .firingCancelled: (firing, observer.member, .observer(observer.member), .observer(observer))
    case .terminalCancelled, .terminalReturned: (terminal.id, Person.execCaller(account), .person(account), .person(terminal))
    }
    let (running, run) = AsyncStream<ExecID>.makeStream()
    let side = FiringProcessSide()
    let mayReturn = Gate()
    defer { side.release.open() }
    let agent = try OperationAgent(machine: machineID.rawValue, kinds: [.init(FiringProcess(side: side))], authorize: { _, _ in })
    let acknowledged = Mutex(false)
    let client = FetchClient { request in
      let response = try await agent.handler(request)
      if request.url.query?.contains("terminalAck=") == true, response.status == .ok {
        acknowledged.withLock { $0 = true }
      }
      return response
    }

    let worker = Spawning { scriptID in
      defer { run.finish() }
      let record = try await space.reserveExec(machine: machineID, caller: caller, script: scriptID)
      // An observer named after the person's persona is not the exec's holder.
      try #require(await server.hub.admitsCaller(record, leg: leg))
      if case .person = leg { #expect(await !server.hub.admitsCaller(record, leg: .observer("nightly@shared"))) }
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(ExecStart(id: record.id, cwd: "/", command: ["wait"]))
      let (serverSocket, clientSocket) = WebSocket.pair()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await server.hub.runCallerSession(record, socket: serverSocket, leg: leg) }
        tasks.addTask { await endpoint.run(WebSocketTransport(clientSocket)) }
        defer { tasks.cancelAll() }
        var events = outgoing.events.makeAsyncIterator()
        _ = try await mixedExecOutput(&events, atLeast: 6)
        #expect(await !server.hub.admitsCaller(record, leg: leg))
        if case .person = leg { #expect(await !server.hub.admitsCaller(record, leg: .observer("nightly@shared"))) }
        run.yield(record.id)
        if case .terminalReturned = end {
          await mayReturn.wait()
          return
        }
        _ = try await mixedExecExit(&events)
      }
    }

    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await server.run() }
      tasks.addTask { await agent.run() }
      defer { side.release.open(); tasks.cancelAll() }
      try await withMachineBox(space: space, hub: server.hub, machine: machineID, client: client) {
        // A firing ends cancelled; a terminal run is cancelled or returns.
        let task = Task {
          try await tokens.runSessionless(sessionless) { token in
            try await worker.run(token: token, script: script)
            if case .firingCancelled = end { throw CancellationError() }
          }
        }
        defer { task.cancel(); mayReturn.open() }
        var started = running.makeAsyncIterator()
        let exec = try #require(await started.next())
        let token = try #require(worker.tokens.withLock { $0.first })
        #expect(tokens.script(ofBearer: token) == sessionless)

        if case .terminalReturned = end { mayReturn.open() } else { task.cancel() }
        _ = try? await task.value
        #expect(tokens.script(ofBearer: token) == nil)
        await side.stopped.wait()
        #expect(side.reason.withLock { $0 == "callerGone" })
        #expect(try await realPollUntil { try await space.execRecord(exec)?.killDelivered == true })

        #expect(acknowledged.withLock { !$0 })
        side.release.open()
        #expect(try await realPollUntil { acknowledged.withLock { $0 } })
        #expect(try await space.liveScriptExecs(script: script, caller: caller).isEmpty)
      }
      await agent.shutdown()
    }
  }
}

extension SessionlessExecReleaseTests {
  @Test func cancellingAScriptJobClosesItsRealExecCallerAndTheMachineStopsIt() async throws {
    try await withSessionDeps { try await proveScriptJobCallerClosure() }
  }
}

private func proveScriptJobCallerClosure() async throws {
  let harness = try await SessionHarness()
  let session = try await harness.createSession(title: "script caller")
  let key = Curve25519.Signing.PrivateKey()
  let enrolled = try await harness.post("/v1/machine-v2", .object(["name": .string("scriptbox"), "pubkey": .string(key.pubkeyLabel)]))
  let enrollment = try await enrolled.json(EnrollConsumeOutput.self)
  let machine = MachineID(rawValue: try #require(enrollment.machine))
  let side = FiringProcessSide()
  defer { side.release.open() }
  let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(FiringProcess(side: side))], authorize: { _, _ in })
  let client = FetchClient { try await agent.handler($0) }
  try await harness.running {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { side.release.open(); tasks.cancelAll() }
      try await withMachineBox(space: harness.space, hub: harness.hub, machine: machine, client: client) {
        let result = try await callResult(harness, session.rawValue, tool: "run_script", .object(["source": .string("""
        import { machine } from "wuhu:machine"
        const process = await machine("scriptbox").spawn("wait")
        for await (const line of process.lines()) break
        result(process.id)
        await process.wait()
        """)]))
        let text = try #require(resultText(result))
        let exec = ExecID(rawValue: String(text.prefix { $0 != "\n" }))
        let note = try #require(text.split(separator: "\n").first { $0.hasPrefix("[script.") })
        let handle = String(note.dropFirst().prefix(15))
        let cancelled = try await callResult(harness, session.rawValue, tool: "cancel", .object(["id": .string(handle)]))
        #expect(resultText(cancelled)?.contains("abort signalled") == true)
        await side.stopped.wait()
        #expect(side.reason.withLock { $0 == "callerGone" })
        #expect(try await realPollUntil { try await harness.space.execRecord(exec)?.killDelivered == true })
        side.release.open()
        #expect(try await realPollUntil { try await harness.space.liveScriptExecs(script: String(handle.dropFirst(7)), caller: session.rawValue).isEmpty })
      }
      await agent.shutdown()
    }
  }
}
