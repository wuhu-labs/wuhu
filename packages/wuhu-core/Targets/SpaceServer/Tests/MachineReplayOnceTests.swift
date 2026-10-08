import Foundation
@testable import MachineChannel
import MachineContract
import SpaceServer
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MachineReplayOnceTests {
  @Test func freshCallerRequestsExactlyOneMappedReplayAndUnboundTerminalAckRetiresThroughHub() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let agent = EndpointHost()
    let first = EndpointHost()
    let fresh = EndpointHost()
    let sent = OutputByteCounter()
    let received = OutputByteCounter()
    let payload = Array(String(repeating: "one replay\n", count: 100).utf8)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask { await agent.run() }
      group.addTask { await first.run() }
      group.addTask { await fresh.run() }
      group.addTask {
        for await exec in agent.endpoint.incomingExecs {
          try await exec.send(.stdout, payload)
          await exec.exit(.exited(code: 0))
        }
      }
      group.addTask {
        for await request in agent.endpoint.inboundRequests {
          if case let .vfs(request) = request { await agent.endpoint.respond(.vfs(VFSResponse(id: request.id, result: .ok))) }
        }
      }
      agent.attach(OutputCountingSender(base: WebSocketTransport(try await connectMachine(server, key: key)), counter: sent))
      try await awaitAttached(server, machine)
      let id = try await mintExec(server, machine: machine)
      let start = makeExecStart(id, command: ["true"])
      let originalSocket = try await connectCaller(server, exec: id)
      first.attach(originalSocket)
      let original = await first.endpoint.startExec(start, autoAcknowledge: false)
      #expect(try await collectExec(original).stdout == payload)
      originalSocket.close()
      #expect(try await realPollUntil { first.completedRounds == 1 })

      let retrySocket = try await connectCaller(server, exec: id)
      fresh.attach(CountingTransport(WebSocketTransport(retrySocket), counter: received))
      let retry = await fresh.endpoint.startExec(start, autoAcknowledge: false)
      #expect(try await collectExec(retry).stdout == payload)
      _ = try await server.hub.vfs(machine: machine, op: .stat(path: "/"))
      #expect(sent.value == 2 * payload.count)
      #expect(received.value == payload.count)
      #expect(await agent.endpoint.retainedExecCount == 1)

      retrySocket.close()
      #expect(try await realPollUntil { fresh.completedRounds == 1 })
      await retry.acknowledgeExit()
      fresh.attach(try await connectCaller(server, exec: id))
      #expect(try await realPollUntil { await agent.endpoint.retainedExecCount == 0 })
      #expect(await fresh.endpoint.retainedExecCount == 0)
      group.cancelAll()
    }
  }
}

private struct OutputCountingSender: FrameTransport {
  let base: WebSocketTransport
  let counter: OutputByteCounter
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    let frame = try FrameCodec.decode(bytes)
    if frame.opcode == .output { counter.add(try frame.payload(OutputChunk.self).data.count) }
    try await base.send(bytes)
  }
}
