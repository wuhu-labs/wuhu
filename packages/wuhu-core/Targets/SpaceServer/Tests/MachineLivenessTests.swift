import Clocks
import JSONValue
import MachineChannel
import MachineContract
import Serve
import SpaceCore
import SpaceServer
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct MachineLivenessTests {
  @Test func attachedButSilentMachineFailsExecAndPendingReadGrepFind() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock(), grace: .seconds(1))
    let (machine, key) = try await addMachine(server)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        let machineSocket = try await connectMachine(server, key: key)
        defer { machineSocket.close() }
        #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
        let exec = try await mintExec(server, machine: machine)
        let caller = try await connectCaller(server, exec: exec)
        let log = FrameLog()
        try await withThrowingTaskGroup(of: Void.self) { readers async throws -> Void in
          readers.addTask {
            for await message in caller.inbound {
              if case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) { log.append(frame) }
            }
            log.finish()
          }
          try await withThrowingTaskGroup(of: Void.self) { calls in
            let path = "machines://\(machine.rawValue)/missing"
            let inputs: [(String, JSONValue)] = [
              ("read", .object(["path": .string(path)])),
              ("grep", .object(["path": .string(path), "pattern": "missing"])),
              ("find", .object(["path": .string(path), "glob": "**/*"])),
            ]
            for (tool, input) in inputs {
              calls.addTask {
                let response = try await server.http(.post, "/v1/tools/\(tool)", json: input)
                #expect(response.status == .unprocessableContent)
                guard case let .object(payload) = try await response.json(JSONValue.self) else {
                  Issue.record("expected a tool error object")
                  return
                }
                #expect(payload["code"] == "unavailable")
                #expect(payload["message"] == .string("machine \(machine.rawValue) stopped responding"))
              }
            }
            try await calls.waitForAll()
          }
          #expect(try await realPollUntil { log.finished() })
          #expect(log.machineLost())
          #expect(try await space.execRecord(exec)?.terminal == .machineLost)
          #expect(await server.hub.attachedMachines().isEmpty)
          readers.cancelAll()
        }
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func callerReboundWithStaleLiveRecordDuringExpiryIsClosed() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    let exec = try await mintExec(server, machine: machine)
    let liveRecord = try #require(try await space.execRecord(exec))
    let (firstMachine, firstMachineLeg) = WebSocket.pair()
    let (firstCaller, firstCallerLeg) = WebSocket.pair()
    let blocked = BlockedCallerSend(firstCallerLeg)
    let currentLog = FrameLog()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.hub.run() }
      group.addTask { await server.hub.runMachineSession(machine, pubkey: key.pubkeyLabel, capabilities: [], socket: firstMachineLeg) }
      group.addTask { await server.hub.runCallerSession(liveRecord, socket: blocked.socket) }
      #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
      try await firstCaller.send(.binary(FrameCodec.encode(
        Frame(streamID: 1, opcode: .execStart, payload: makeExecStart(exec, command: ["true"])),
      )))
      for await message in firstMachine.inbound {
        if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .execStart { break }
      }
      await clock.advance(by: .seconds(61))
      #expect(try await realPollUntil { blocked.started })
      #expect(try await space.execRecord(exec)?.terminal == .machineLost)

      let (secondMachine, secondMachineLeg) = WebSocket.pair()
      defer { secondMachine.close() }
      group.addTask { await server.hub.runMachineSession(machine, pubkey: key.pubkeyLabel, capabilities: [], socket: secondMachineLeg) }
      #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
      try await secondMachine.send(.binary(FrameCodec.encode(
        Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1)),
      )))
      let (currentCaller, currentCallerLeg) = WebSocket.pair()
      defer { currentCaller.close() }
      group.addTask {
        for await message in currentCaller.inbound {
          if case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) { currentLog.append(frame) }
        }
        currentLog.finish()
      }
      group.addTask { await server.hub.runCallerSession(liveRecord, socket: currentCallerLeg) }
      #expect(try await realPollUntil { currentLog.finished() })
      #expect(try await space.execRecord(exec)?.terminal == .machineLost)
      await clock.advance(by: .milliseconds(101))
      #expect(try await realPollUntil { blocked.aborted })
      group.cancelAll()
    }
  }

  @Test func backpressuredCallerCannotHoldOtherLossRecordsOrLegsOpen() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock(), grace: .seconds(1))
    let (machine, key) = try await addMachine(server)
    let blockedExec = try await mintExec(server, machine: machine)
    let otherExec = try await mintExec(server, machine: machine)
    let blockedRecord = try #require(try await space.execRecord(blockedExec))
    let otherRecord = try #require(try await space.execRecord(otherExec))
    let (machineSocket, machineLeg) = WebSocket.pair()
    let (blockedCaller, blockedLeg) = WebSocket.pair()
    let (otherCaller, otherLeg) = WebSocket.pair()
    defer { machineSocket.close(); blockedCaller.close(); otherCaller.close() }
    let blocked = BlockedCallerSend(blockedLeg)
    let otherLog = FrameLog()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.hub.run() }
      group.addTask { await server.hub.runMachineSession(machine, pubkey: key.pubkeyLabel, capabilities: [], socket: machineLeg) }
      group.addTask { await server.hub.runCallerSession(blockedRecord, socket: blocked.socket) }
      group.addTask { await server.hub.runCallerSession(otherRecord, socket: otherLeg) }
      group.addTask {
        for await message in otherCaller.inbound {
          if case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) { otherLog.append(frame) }
        }
        otherLog.finish()
      }
      #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
      for (exec, caller) in [(blockedExec, blockedCaller), (otherExec, otherCaller)] {
        try await caller.send(.binary(FrameCodec.encode(
          Frame(streamID: 1, opcode: .execStart, payload: makeExecStart(exec, command: ["true"])),
        )))
      }
      var starts = 0
      for await message in machineSocket.inbound {
        if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .execStart { starts += 1 }
        if starts == 2 { break }
      }
      #expect(try await realPollUntil { blocked.started && otherLog.finished() })
      #expect(otherLog.machineLost())
      #expect(try await space.execRecord(blockedExec)?.terminal == .machineLost)
      #expect(try await space.execRecord(otherExec)?.terminal == .machineLost)
      #expect(try await realPollUntil { blocked.aborted })
      group.cancelAll()
    }
  }

  @Test func terminalDrainAtSilenceExpiryKeepsTheKnownVerdict() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    let exec = try await mintExec(server, machine: machine)
    try await space.finishExec(exec, .exited(code: 0))
    let record = try #require(try await space.execRecord(exec))
    let (machineSocket, machineLeg) = WebSocket.pair()
    let (caller, callerLeg) = WebSocket.pair()
    defer { machineSocket.abort(); caller.abort() }
    let log = FrameLog()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.hub.run() }
      group.addTask { await server.hub.runMachineSession(machine, pubkey: key.pubkeyLabel, capabilities: [], socket: machineLeg) }
      #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
      await clock.advance(by: .seconds(40))
      group.addTask { await server.hub.runCallerSession(record, socket: callerLeg) }
      group.addTask {
        for await message in caller.inbound {
          guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes) else { continue }
          log.append(frame)
          if frame.opcode == .control, case let .error(error) = try frame.payload(ControlMessage.self) {
            #expect(error == MachineError(code: .execNotFound, message: "exec \(exec.rawValue) is finished and its stream is no longer replayable"))
          }
        }
        log.finish()
      }
      try await caller.send(.binary(FrameCodec.encode(
        Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1)),
      )))
      for await message in machineSocket.inbound {
        if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .control { break }
      }
      await clock.advance(by: .seconds(21))
      #expect(try await realPollUntil { log.finished() })
      #expect(log.stalledDrain())
      #expect(!log.machineLost())
      #expect(await server.hub.attachedMachines().isEmpty)
      #expect(try await space.execRecord(exec)?.terminal == .exited(code: 0))
      group.cancelAll()
    }
  }

  @Test func socketRebindWithoutMachineEvidenceDoesNotRenewSilenceWindow() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock()
    let server = TestServer(space: space, clock: clock)
    let (machine, key) = try await addMachine(server)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        let first = try await connectMachine(server, key: key)
        defer { first.close() }
        #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
        await clock.advance(by: .seconds(40))
        let second = try await connectMachine(server, key: key)
        defer { second.close() }
        for await _ in first.inbound {}
        let exec = try await mintExec(server, machine: machine)
        let caller = try await connectCaller(server, exec: exec)
        defer { caller.close() }
        await clock.advance(by: .seconds(21))
        #expect(try await realPollUntil { try await space.execRecord(exec)?.terminal == .machineLost })
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func installedAgentKeepsSilentCommandAliveThroughStatProbes() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock(), grace: .seconds(1))
    let (machine, key) = try await addMachine(server)
    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      host.attach(try await connectCaller(server, exec: exec))
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["sh", "-c", "sleep 3; echo survived"]))
      var output = ""
      var exited = false
      for try await event in outgoing.events {
        switch event {
        case let .output(_, _, data): output += String(decoding: data.bytes, as: UTF8.self)
        case let .exit(status):
          #expect(status == .exited(code: 0))
          exited = true
        case .truncated: break
        case let .failed(error): Issue.record("silent healthy command failed: \(error)")
        }
      }
      #expect(exited)
      #expect(output == "survived\n")
      #expect(try await space.execRecord(exec)?.terminal == .exited(code: 0))
    }
  }
}

private final class BlockedCallerSend: Sendable {
  private struct State {
    var started = false
    var aborted = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())
  private let base: WebSocket

  init(_ base: WebSocket) {
    self.base = base
  }

  var started: Bool { state.withLock { $0.started } }
  var aborted: Bool { state.withLock { $0.aborted } }

  var socket: WebSocket {
    WebSocket(inbound: base.inbound, send: { _ in
      await withCheckedContinuation { waiter in
        let aborted = self.state.withLock { state in
          state.started = true
          if !state.aborted { state.waiters.append(waiter) }
          return state.aborted
        }
        if aborted { waiter.resume() }
      }
      throw ServeError.webSocketClosed
    }, close: {}, abort: {
      let waiters = self.state.withLock { state in
        state.aborted = true
        let waiters = state.waiters
        state.waiters.removeAll()
        return waiters
      }
      self.base.abort()
      for waiter in waiters { waiter.resume() }
    })
  }
}
