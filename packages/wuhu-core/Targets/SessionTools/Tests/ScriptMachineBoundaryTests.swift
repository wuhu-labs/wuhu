import Dependencies
import MachineChannel
import struct MachineContract.ExecID
import func MainHub.execEnvironment
import class MainHub.Hub
import struct MainHub.ScriptError
import struct MainHub.ScriptExecStream
import struct MainHub.ScriptMachineAccess
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct ScriptMachineBoundaryTests {
  @Test func releaseJoinsCallerLegAndDoesNotKillRemoteProcess() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let files = FakeMachineFS()
      files.attached.withLock { _ = $0.insert(machine) }
      let connected = Gate()
      let closed = Box(0)
      let scripted = ScriptedExecMachine()
      var backend = scripted.backend(space)
      backend.connect = { _ in
        let (caller, _) = InMemoryTransport.pair()
        connected.open()
        return ClosingTransport(base: caller, closed: closed)
      }
      let main = Hub(space: space, scriptMachines: ScriptMachineAccess(files: files.seam, exec: backend))
      let run = try await main.startScriptExec(session: session, script: .init("script"), request: .init(
        machine: machine, cwd: "/", command: "cat", environment: try execEnvironment(env: [:], secrets: [:]), window: 1024,
        maxOutput: nil, timeout: nil, acceptsStdin: true, autoAcknowledge: false,
      ))
      await connected.wait()
      await #expect(throws: ScriptError.self) {
        try await main.scriptExecInput(session: session, script: .init("other"), exec: run.id, input: .release)
      }
      #expect(closed.value == 0)
      try await main.scriptExecInput(session: session, script: .init("script"), exec: run.id, input: .release)
      #expect(closed.value == 1)
      #expect(scripted.kills.value.isEmpty)
      #expect(try await space.execRecord(run.id)?.terminal == nil)
      var events = run.events.makeAsyncIterator()
      #expect(try await events.next() == nil)
      try await main.scriptExecInput(session: session, script: .init("script"), exec: run.id, input: .release)
      await #expect(throws: ScriptError.self) {
        try await main.scriptExecInput(session: session, script: .init("script"), exec: run.id, input: .write([1]))
      }
      try await main.scriptExecInput(session: session, script: .init("script"), exec: run.id, input: .kill(.recorded))
      #expect(scripted.kills.value == [run.id])
    }
  }

  @Test func droppingHubCancelsCallerLegWithoutRetainingHub() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let files = FakeMachineFS()
      files.attached.withLock { _ = $0.insert(machine) }
      let connected = Gate()
      let closed = Gate()
      var backend = ScriptedExecMachine().backend(space)
      backend.connect = { _ in
        let (caller, _) = InMemoryTransport.pair()
        connected.open()
        return SignallingTransport(base: caller, closed: closed)
      }
      var main: Hub? = Hub(space: space, scriptMachines: ScriptMachineAccess(files: files.seam, exec: backend))
      weak let weakMain = main
      let run = try await main!.startScriptExec(session: session, script: .init("script"), request: .init(
        machine: machine, cwd: "/", command: "cat", environment: try execEnvironment(env: [:], secrets: [:]), window: 1024,
        maxOutput: nil, timeout: nil, acceptsStdin: true, autoAcknowledge: false,
      ))
      await connected.wait()
      main = nil
      #expect(weakMain == nil)
      await closed.wait()
      var events = run.events.makeAsyncIterator()
      #expect(try await events.next() == nil)
    }
  }
}

private struct ClosingTransport: FrameTransport {
  let base: InMemoryTransport
  let closed: Box<Int>
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func send(_ bytes: [UInt8]) async throws { try await base.send(bytes) }
  func close() { closed.withLock { $0 += 1 }; base.close() }
}

private struct SignallingTransport: FrameTransport {
  let base: InMemoryTransport
  let closed: Gate
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func send(_ bytes: [UInt8]) async throws { try await base.send(bytes) }
  func close() { base.close(); closed.open() }
}
