import Clocks
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
import enum SpaceContract.ScriptOutput
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private final class Spawning: Worker, Sendable {
  let tokens = Mutex<[String]>([])
  let spawn: @Sendable (ScriptHandlerInvocation) async throws -> Void

  init(spawn: @escaping @Sendable (ScriptHandlerInvocation) async throws -> Void) { self.spawn = spawn }

  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    tokens.withLock { $0.append(invocation.token ?? "") }
    try await spawn(invocation)
    throw CancellationError()
  }

  func deliver(_ session: SessionID, _ input: WorkerInput) async throws {}
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool { true }
  func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {}
  func activity() async -> WorkerActivity { WorkerActivity(scripts: [:]) }
  func runningWork(_ session: SessionID) async throws -> [String] { [] }
  func shutdown() async {}
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

@Suite(.deterministicDependencies(clock: ContinuousClock())) struct ObserverExecReleaseTests {
  @Test func cancellingAFiringRevokesItsTokenAndKillsTheProcessItsScriptStarted() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: TestClock())
    let (machineID, _) = try await addMachine(server)
    let tokens = ExecTokens(spaceURL: "http://main")
    let registry = WorkerRegistry(tokens: tokens, machines: server.hub)
    let observer = Observer(group: .shared, name: "nightly", firing: "f1")
    let invocation = ScriptHandlerInvocation(id: UUID(), path: "/nightly.js", runner: .observer(observer), input: .timer(Date()), stateJSON: nil)
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

    let worker = Spawning { invocation in
      let record = try await space.mintScriptExec(machine: machineID, caller: observer.member, script: invocation.scriptID)
      await server.hub.noteMinted(record)
      let caller = ChannelEndpoint()
      let outgoing = await caller.startExec(ExecStart(id: record.id, cwd: "/", command: ["wait"]))
      let (serverSocket, clientSocket) = WebSocket.pair()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await server.hub.runCallerSession(record, socket: serverSocket, leg: .observer(observer.member)) }
        tasks.addTask { await caller.run(WebSocketTransport(clientSocket)) }
        defer { tasks.cancelAll() }
        var events = outgoing.events.makeAsyncIterator()
        _ = try await mixedExecOutput(&events, atLeast: 6)
        run.yield(record.id)
        _ = try await mixedExecExit(&events)
      }
    }
    registry.announce(registry.mint().id, endpoint: worker)

    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await server.run() }
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { side.release.open(); tasks.cancelAll() }
      let firing = Task { try await registry.fire(invocation) }
      var started = running.makeAsyncIterator()
      let exec = try #require(await started.next())
      let token = try #require(worker.tokens.withLock { $0.first })
      #expect(tokens.observer(ofBearer: token) == observer)

      firing.cancel()
      _ = try? await firing.value
      #expect(tokens.observer(ofBearer: token) == nil)
      await side.stopped.wait()
      #expect(side.reason.withLock { $0 } == "callerCancelled")
      #expect(try await space.execRecord(exec)?.terminal == .cancelled)
      #expect(try await space.liveScriptExecs(script: invocation.scriptID, caller: observer.member).isEmpty)
      #expect(try await space.takeScriptExecOwners().isEmpty)

      #expect(acknowledged.withLock { !$0 })
      side.release.open()
      #expect(try await realPollUntil { acknowledged.withLock { $0 } })
      await agent.shutdown(); await service.shutdown()
    }
  }
}
