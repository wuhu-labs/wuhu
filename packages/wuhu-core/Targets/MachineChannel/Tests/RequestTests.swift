import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct RequestTests {
  @Test func vfsAndSearchRoundTrip() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine) }
      group.addTask { await serveRequestsOK(machine) }
      let stat = try await vfsRetryingUntilBound(caller, .stat(path: "/"))
      #expect(stat == .ok)
      let found = try await caller.search(.find(glob: "*", path: nil, matchLimit: nil, entryLimit: nil, step: nil))
      #expect(found == .paths(paths: [], cursor: nil))
      group.cancelAll()
    }
  }

  @Test func concurrentRequestsCorrelateByIdAcrossOutOfOrderResponses() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await drive(caller, machine) }
      group.addTask {
        var pending: [VFSRequest] = []
        for await request in machine.inboundRequests {
          guard case let .vfs(vfsRequest) = request else { continue }
          if case .stat = vfsRequest.op {
            await machine.respond(.vfs(VFSResponse(id: vfsRequest.id, result: .ok)))
            continue
          }
          pending.append(vfsRequest)
          if pending.count == 2 {
            for held in pending.reversed() {
              guard case let .write(path, _, _) = held.op else { continue }
              await machine.respond(.vfs(VFSResponse(id: held.id, result: .written(token: path))))
            }
            pending.removeAll()
          }
        }
      }
      _ = try await vfsRetryingUntilBound(caller, .stat(path: "/probe"))
      async let first = caller.vfs(.write(path: "/a", data: Base64Data([1]), ifMatch: nil))
      async let second = caller.vfs(.write(path: "/b", data: Base64Data([2]), ifMatch: nil))
      let (firstResult, secondResult) = try await (first, second)
      #expect(firstResult == .written(token: "/a"))
      #expect(secondResult == .written(token: "/b"))
      group.cancelAll()
    }
  }

  @Test func inFlightRequestFailsOnSever() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let (callerSide, machineSide) = InMemoryTransport.pair()
    let requestSeen = Checkpoint()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(callerSide) }
      group.addTask { await machine.run(machineSide) }
      group.addTask {
        for await _ in machine.inboundRequests {
          requestSeen.signal()
        }
      }
      group.addTask {
        await requestSeen.wait()
        callerSide.sever()
      }
      await #expect(throws: ChannelError.severed) {
        _ = try await caller.vfs(.stat(path: "/"))
      }
      group.cancelAll()
    }
  }

  @Test func requestWhileUnboundFailsImmediately() async throws {
    let caller = ChannelEndpoint()
    await #expect(throws: ChannelError.severed) {
      _ = try await caller.vfs(.stat(path: "/"))
    }
  }

  @Test func malformedFrameGetsControlErrorAndThePumpSurvives() async throws {
    let machine = ChannelEndpoint()
    let (raw, machineSide) = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await machine.run(machineSide) }
      group.addTask { await serveRequestsOK(machine) }
      try await raw.send(Array("definitely not a frame".utf8))
      try await raw.send(FrameCodec.encode(Frame(streamID: 0, opcode: .vfsRequest, payload: VFSRequest(id: 7, op: .stat(path: "/")))))
      var protocolError: MachineError?
      var response: VFSResponse?
      for await bytes in raw.inbound {
        let frame = try FrameCodec.decode(bytes)
        if frame.opcode == .control, case let .error(error) = try frame.payload(ControlMessage.self) {
          protocolError = error
        }
        if frame.opcode == .vfsResponse {
          response = try frame.payload(VFSResponse.self)
        }
        if protocolError != nil, response != nil { break }
      }
      #expect(protocolError?.code == .protocolViolation)
      #expect(response == VFSResponse(id: 7, result: .ok))
      group.cancelAll()
    }
  }

  @Test func inFlightRequestFailsWhenTheResponderLegBlips() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let relay = Relay()
    let requestSeen = Checkpoint()
    let legB1 = InMemoryTransport.pair()
    try await withThrowingTaskGroup(of: Void.self) { group in
      let legA = InMemoryTransport.pair()
      group.addTask { await caller.run(legA.0) }
      group.addTask { await relay.runA(legA.1) }
      group.addTask {
        // Responder leg: severed while a request is in flight, then rebinds.
        async let machineRun: Void = machine.run(legB1.1)
        async let relayRun: Void = relay.runB(legB1.0)
        _ = await (machineRun, relayRun)
        let legB2 = InMemoryTransport.pair()
        async let machineRerun: Void = machine.run(legB2.1)
        async let relayRerun: Void = relay.runB(legB2.0)
        _ = await (machineRerun, relayRerun)
      }
      group.addTask {
        for await request in machine.inboundRequests {
          guard case let .vfs(vfsRequest) = request else { continue }
          if case let .stat(path) = vfsRequest.op, path == "/probe" {
            await machine.respond(.vfs(VFSResponse(id: vfsRequest.id, result: .ok)))
          } else {
            requestSeen.signal()
          }
        }
      }
      group.addTask {
        await requestSeen.wait()
        legB1.0.sever()
      }
      _ = try await vfsRetryingUntilBound(caller, .stat(path: "/probe"))
      // The caller's own binding never blips; the machine's rebind hello is
      // what must fail this round trip instead of leaving it hanging.
      await #expect(throws: ChannelError.severed) {
        _ = try await caller.vfs(.stat(path: "/held"))
      }
      group.cancelAll()
    }
  }
}
