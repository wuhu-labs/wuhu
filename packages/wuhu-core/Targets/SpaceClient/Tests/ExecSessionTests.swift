import DeterministicDependencies
import Fetch
import MachineChannel
import MachineContract
import SpaceClient
import Synchronization
import Testing

@Suite(.deterministicDependencies(clock: ContinuousClock()), .timeLimit(.minutes(1))) struct ExecSessionTests {
  @Test func manualExitAcknowledgementKeepsTheCallerLegUntilSettlement() async throws {
    let (caller, peer) = InMemoryTransport.pair()
    let transport = RecordingTransport(caller)
    let events = Mutex<[ExecEvent]>([])
    let output = Mutex<[UInt8]>([])
    let (ended, end) = AsyncStream<Void>.makeStream()
    let (committed, commit) = AsyncStream<Void>.makeStream()
    let start = ExecStart(id: ExecID(rawValue: "exec_manual"), cwd: "/", command: ["echo"], maxOutput: 100)
    let client = SpaceClient(space: "http://main", fetch: FetchClient { _ in
      Issue.record("a connected exec should not fetch status")
      return Response(status: .internalServerError)
    }, dial: { _, _ in transport })
    let session = ExecSession(client: client, start: start)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        let termination = try await session.run(autoAcknowledge: false, input: .closed, output: { _, bytes in
          output.withLock { $0 += bytes }
        }, onEvent: { event in
          events.withLock { $0.append(event) }
        }, onTermination: { termination in
          #expect(termination == .signaled(9, outputLimitReached: false))
          end.yield(())
          for await _ in committed {}
          await session.acknowledgeExit()
          #expect(transport.terminalAck.withLock { $0 })
        })
        #expect(termination == .signaled(9, outputLimitReached: false))
      }
      for frame in [
        Frame(streamID: 1, opcode: .ack, payload: Ack(id: start.id, cursor: 0)),
        Frame(streamID: 1, opcode: .output, payload: OutputChunk(id: start.id, stream: .stdout, cursor: 0, data: Base64Data([1, 2, 3]))),
        Frame(streamID: 1, opcode: .execExit, payload: ExecExit(id: start.id, cursor: 3, status: .signaled(signal: 9), outputCut: true, timedOut: .killed)),
      ] {
        try await peer.send(FrameCodec.encode(frame))
      }
      for await _ in ended { break }
      #expect(!transport.closed.withLock { $0 })
      #expect(!transport.terminalAck.withLock { $0 })
      #expect(output.withLock { $0 } == [1, 2, 3])
      let received = events.withLock { $0 }
      #expect(received.contains(.truncated(limit: 3)))
      #expect(received.contains(.timedOut(outcome: .killed)))
      commit.finish()
      // The exec task completes only after its explicit acknowledgement.
      _ = try await group.next()
      group.cancelAll()
    }
    #expect(transport.closed.withLock { $0 })
    #expect(transport.terminalAck.withLock { $0 })
  }

  @Test func finalDialRefusalTerminatesWithoutRedialing() async throws {
    let client = SpaceClient(space: "http://main", fetch: FetchClient { _ in
      Issue.record("a final refusal must not fetch status")
      return Response(status: .internalServerError)
    }, dial: { _, _ in
      throw SpaceClient.DialRefusal(status: 403, body: Array("denied".utf8))
    })
    let session = ExecSession(client: client, start: ExecStart(id: ExecID(rawValue: "exec_refused"), cwd: "/", command: ["echo"]))
    let termination = try await session.run(input: .closed, output: { _, _ in })
    #expect(termination == .streamFailed("403: denied"))
  }
}

private final class RecordingTransport: FrameTransport, Sendable {
  let base: InMemoryTransport
  let terminalAck = Mutex(false)
  let closed = Mutex(false)
  var inbound: AsyncStream<[UInt8]> { base.inbound }

  init(_ base: InMemoryTransport) { self.base = base }

  func send(_ bytes: [UInt8]) async throws {
    let frame = try FrameCodec.decode(bytes)
    if frame.opcode == .ack, try frame.payload(Ack.self).terminal == true {
      terminalAck.withLock { $0 = true }
    }
    try await base.send(bytes)
  }

  func close() {
    closed.withLock { $0 = true }
    base.close()
  }
}
