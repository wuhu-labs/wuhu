import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
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
    let time = LivenessTime()
    let server = time.server(space: space)
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
        try await caller.send(.binary(FrameCodec.encode(
          Frame(streamID: 1, opcode: .execStart, payload: makeExecStart(exec, command: ["true"])),
        )))
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
            var requests = 0
            var callerBound = false
            for await message in machineSocket.inbound {
              guard case let .binary(bytes) = message else { continue }
              let frame = try FrameCodec.decode(bytes)
              switch frame.opcode {
              case .control: callerBound = true
              case .vfsRequest:
                if case .read = try frame.payload(VFSRequest.self).op { requests += 1 }
              case .searchRequest: requests += 1
              default: break
              }
              if requests == 3, callerBound { break }
            }
            #expect(requests == 3)
            #expect(callerBound)
            try await time.control.asleep("machine silence", dueIn: 60)
            await time.advance(to: 60.000001)
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
    let time = LivenessTime()
    let server = time.server(space: space)
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
      try await time.control.asleep("machine silence", dueIn: 60)
      await time.advance(to: 60.000001)
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
      try await time.control.asleep("blocked loss send", dueIn: 0.1)
      await time.advance(to: 60.100002)
      #expect(try await realPollUntil { blocked.aborted })
      group.cancelAll()
    }
  }

  @Test func backpressuredCallerCannotHoldOtherLossRecordsOrLegsOpen() async throws {
    let space = try makeMachineSpace()
    let time = LivenessTime()
    let server = time.server(space: space)
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
      try await time.control.asleep("machine silence", dueIn: 60)
      await time.advance(to: 60.000001)
      #expect(try await realPollUntil { blocked.started && otherLog.finished() })
      #expect(otherLog.machineLost())
      #expect(try await space.execRecord(blockedExec)?.terminal == .machineLost)
      #expect(try await space.execRecord(otherExec)?.terminal == .machineLost)
      try await time.control.asleep("blocked loss send", dueIn: 0.1)
      await time.advance(to: 60.100002)
      #expect(try await realPollUntil { blocked.aborted })
      group.cancelAll()
    }
  }

  @Test func terminalDrainAtSilenceExpiryKeepsTheKnownVerdict() async throws {
    let space = try makeMachineSpace()
    let time = LivenessTime()
    let server = time.server(space: space)
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
      try await time.control.asleep("machine silence", dueIn: 60)
      await time.advance(to: 40)
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
        Frame(streamID: 1, opcode: .execStart, payload: makeExecStart(exec, command: ["true"])),
      )))
      for await message in machineSocket.inbound {
        if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .control { break }
      }
      await time.advance(to: 60.000001)
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
    let time = LivenessTime()
    let server = time.server(space: space)
    let (machine, key) = try await addMachine(server)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        let first = try await connectMachine(server, key: key)
        defer { first.close() }
        #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
        try await time.control.asleep("machine silence", dueIn: 60)
        await time.advance(to: 40)
        let second = try await connectMachine(server, key: key)
        defer { second.close() }
        for await _ in first.inbound {}
        let exec = try await mintExec(server, machine: machine)
        let caller = try await connectCaller(server, exec: exec)
        defer { caller.close() }
        try await caller.send(.binary(FrameCodec.encode(
          Frame(streamID: 1, opcode: .execStart, payload: makeExecStart(exec, command: ["true"])),
        )))
        for await message in second.inbound {
          if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .control { break }
        }
        await time.advance(to: 60.000001)
        #expect(try await realPollUntil { try await space.execRecord(exec)?.terminal == .machineLost })
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func installedAgentKeepsSilentCommandAliveThroughStatProbes() async throws {
    let space = try makeMachineSpace()
    let time = LivenessTime()
    let server = time.server(space: space)
    let (machine, key) = try await addMachine(server)
    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      let responses = Mutex(0)
      dialer.offer(WebSocket(inbound: machineSocket.inbound, send: { message in
        try await machineSocket.send(message)
        if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .vfsResponse {
          responses.withLock { $0 += 1 }
        }
      }, close: { machineSocket.close() }, abort: { machineSocket.abort() }))
      let exec = try await mintExec(server, machine: machine)
      host.attach(try await connectCaller(server, exec: exec))
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["sh", "-c", "printf 'ready\\n'; cat"]))
      var iterator = outgoing.events.makeAsyncIterator()
      var output = ""
      while !output.contains("ready\n"), let event = try await iterator.next() {
        if case let .output(_, _, data) = event { output += String(decoding: data.bytes, as: UTF8.self) }
      }
      try #require(output == "ready\n")
      try await time.control.asleep("machine silence", dueIn: 60)
      for tick in 1 ... 4 {
        let before = responses.withLock { $0 }
        try await time.waitForSleeps(tick == 3 ? 2 : 1, dueIn: 20)
        await time.advance(to: Double(tick * 20) + Double(tick) * 1e-6)
        try #require(try await realPollUntil { responses.withLock { $0 } > before })
        // The round trip proves the hub processed the preceding automatic probe response.
        guard case .entry = try await server.hub.vfs(machine: machine, op: .stat(path: "/")) else {
          Issue.record("installed agent did not answer stat")
          return
        }
        #expect(await server.hub.attachedMachines().contains(machine))
        #expect(try await space.execRecord(exec)?.terminal == nil)
      }
      try await outgoing.sendStdin(Array("survived\n".utf8))
      await outgoing.closeStdin()
      var exited = false
      while let event = try await iterator.next() {
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
      #expect(output == "ready\nsurvived\n")
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

private struct LivenessTime: Sendable {
  private let clock: any Clock<Duration>
  let control: TimeControl

  init() {
    (clock, control) = withDependencies {
      $0.installTimeControl()
    } operation: {
      @Dependency(\.continuousClock) var clock
      @Dependency(\.timeControl) var control
      return (clock, control)
    }
  }

  func server(space: Space) -> TestServer {
    // Distinct, shorter deadlines keep silence/probe sleep registration unambiguous.
    TestServer(space: space, clock: clock, callerGrace: .seconds(10), keyRecheck: .seconds(10))
  }

  func waitForSleeps(_ count: Int, dueIn seconds: Double) async throws {
    try #require(try await realPollUntil { control.sleeping(dueIn: seconds) >= count })
  }

  func advance(to seconds: Double) async {
    await control.advance(to: Date(timeIntervalSinceReferenceDate: seconds))
  }
}
