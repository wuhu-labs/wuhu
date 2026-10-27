import Clocks
import DeterministicDependencies
import Foundation
import MachineChannel
import MachineContract
import MainHub
import SessionDomain
import enum SpaceContract.ScriptOutput
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// A firing's worker that starts a process for its handler's script and holds
// its caller line open: cancelled, it can no longer reach main to stop it.
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

@Suite(.deterministicDependencies(clock: ContinuousClock())) struct ObserverExecReleaseTests {
  @Test func cancellingAFiringRevokesItsTokenAndKillsTheProcessItsScriptStarted() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: TestClock())
    let (machineID, key) = try await addMachine(server)
    let tokens = ExecTokens(spaceURL: "http://main")
    let registry = WorkerRegistry(tokens: tokens, machines: server.hub)
    let observer = Observer(group: .shared, name: "nightly", firing: "f1")
    let invocation = ScriptHandlerInvocation(id: UUID(), path: "/nightly.js", runner: .observer(observer), input: .timer(Date()), stateJSON: nil)
    let (running, run) = AsyncStream<ExecID>.makeStream()
    let killed = Mutex<[ExecID]>([])

    let worker = Spawning { invocation in
      let record = try await space.mintScriptExec(machine: machineID, caller: observer.member, script: invocation.scriptID)
      await server.hub.noteMinted(record)
      let caller = ChannelEndpoint()
      _ = await caller.startExec(makeExecStart(record.id, command: ["sleep"]))
      let socket = try await connectCaller(server, exec: record.id)
      await caller.run(WebSocketTransport(socket))
    }
    registry.announce(registry.mint().id, endpoint: worker)

    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask { await machine.run(WebSocketTransport(try await connectMachine(server, key: key))) }
      group.addTask {
        for await exec in machine.incomingExecs {
          run.yield(exec.start.id)
          for await _ in exec.kills {
            killed.withLock { $0.append(exec.start.id) }
            await exec.exit(.signaled(signal: 15))
            break
          }
        }
      }
      group.addTask {
        #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machineID) })
        let firing = Task { try await registry.fire(invocation) }
        var started = running.makeAsyncIterator()
        let exec = try #require(await started.next())
        let first = worker.tokens.withLock { $0.first }
        let token = try #require(first)
        #expect(tokens.observer(ofBearer: token) == observer)

        firing.cancel()
        _ = try? await firing.value
        #expect(tokens.observer(ofBearer: token) == nil)
        #expect(try await realPollUntil { killed.withLock { $0 } == [exec] })
        #expect(try await space.execRecord(exec)?.terminal == .cancelled)
        #expect(try await space.liveScriptExecs(script: invocation.scriptID, caller: observer.member).isEmpty)
        #expect(try await space.takeScriptExecOwners().isEmpty)
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }
}
