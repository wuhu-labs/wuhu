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
import struct SpaceContract.GroupID
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

  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
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
  // The script's own leg attaches to the exec it minted and reads it; when its
  // run ends, cancelled or not, its token is revoked and main kills the exec
  // and forgets its owner row.
  @Test(arguments: [SessionlessEnd.firingCancelled, .terminalCancelled, .terminalReturned])
  func aRunsEndRevokesItsTokenAndKillsTheProcessItsScriptStarted(_ end: SessionlessEnd) async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: VirtualClock())
    let (machineID, _) = try await addMachine(server)
    let tokens = ExecTokens(spaceURL: "http://main")
    let observer = Observer(group: .shared, name: "nightly", firing: "f1")
    let firing = handlerScriptID(UUID())
    let account = AccountID(rawValue: "ac_alice001")
    let terminal = TerminalRun(id: "terminal-1", persona: "nightly", account: account, group: .shared, personalGroup: GroupID(rawValue: "alice"))
    let (script, caller, leg, sessionless): (String, String, ExecLeg, SessionlessScript) = switch end {
    case .firingCancelled: (firing, observer.member, .observer(observer.member), .observer(observer))
    case .terminalCancelled, .terminalReturned: (terminal.id, Person.execCaller(account), .person(account), .person(terminal))
    }
    let (running, run) = AsyncStream<ExecID>.makeStream()
    let side = FiringProcessSide()
    defer { side.release.open() }
    let agent = try OperationAgent(machine: machineID.rawValue, kinds: [.init(FiringProcess(side: side))], authorize: { _, _ in })
    let acknowledged = Mutex(false)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      let response = try await agent.handler(request)
      if request.url.query?.contains("terminalAck=") == true, response.status == .ok {
        acknowledged.withLock { $0 = true }
      }
      return response
    } })
    await server.hub.configureV2(service)

    let worker = Spawning { scriptID in
      let record = try await space.mintScriptExec(machine: machineID, caller: caller, script: scriptID)
      await server.hub.noteMinted(record)
      // An observer named after the person's persona is not the exec's holder.
      #expect(await server.hub.admitsCaller(record, leg: leg))
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
        run.yield(record.id)
        if case .terminalReturned = end { return }
        _ = try await mixedExecExit(&events)
      }
    }

    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await server.run() }
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { side.release.open(); tasks.cancelAll() }
      // A firing ends cancelled; a terminal run is cancelled or returns.
      let task = Task {
        try await tokens.runSessionless(sessionless, script: script, machines: server.hub) { token in
          try await worker.run(token: token, script: script)
          if case .firingCancelled = end { throw CancellationError() }
        }
      }
      var started = running.makeAsyncIterator()
      let exec = try #require(await started.next())
      let token = try #require(worker.tokens.withLock { $0.first })
      #expect(tokens.script(ofBearer: token) == sessionless)

      if case .terminalReturned = end {} else { task.cancel() }
      _ = try? await task.value
      #expect(tokens.script(ofBearer: token) == nil)
      await side.stopped.wait()
      #expect(side.reason.withLock { $0 } == "callerCancelled")
      #expect(try await space.execRecord(exec)?.terminal == .cancelled)
      #expect(try await space.liveScriptExecs(script: script, caller: caller).isEmpty)
      #expect(try await space.takeScriptExecOwners().isEmpty)

      #expect(acknowledged.withLock { !$0 })
      side.release.open()
      #expect(try await realPollUntil { acknowledged.withLock { $0 } })
      await agent.shutdown(); await service.shutdown()
    }
  }
}
