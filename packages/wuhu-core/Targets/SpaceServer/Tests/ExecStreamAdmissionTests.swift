import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationProtocol
import OperationRuntime
import Serve
@testable import SpaceCore
@testable import SpaceServer
import Testing
import Wuwei

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct ExecStreamAdmissionTests {
  @Test func anAdmittedAdapterCanFinishItsCleanupAfterTheSpaceHasClosed() async throws {
    let space = try makeMachineSpace()
    let machine = try await space.addMachineV2(name: "late_cleanup", group: .shared).machine.id
    let record = try await space.reserveExec(machine: machine, group: .shared)
    let cell = MachineCell.ID(machine.rawValue)
    let described = Gate()
    let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
    let box = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 1024)) {
      if case let .frame(frame) = $0, frame.tag == .describe { described.open() }
    })
    defer { box.close() }
    await described.wait()
    box.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
    while try await space.worker.call(cell, { $0.presence.pollHoldMs == nil }) { try Task.checkCancellation() }
    let wire = AdmissionWire()
    defer { wire.finish() }
    try await withThrowingTaskGroup(of: Void.self) { adapters in
      adapters.addTask { await ExecSocketLink(space: space, record: record, leg: .anonymous).run(wire.socket(blockAcceptance: true)) }
      defer { wire.releaseAcceptance.open(); adapters.cancelAll() }
      var frames = wire.outgoing.stream.makeAsyncIterator()
      #expect(try #require(await frames.next()).opcode == .control)
      wire.send(Frame(streamID: 7, opcode: .execStart, payload: ExecStart(id: record.id, cwd: "/", command: ["not-dispatched"])))
      await wire.acceptance.wait()
      try Task.checkCancellation()
      #expect(!wire.closed.isOpen)
      try await space.close()
      #expect(!wire.closed.isOpen)
      wire.releaseAcceptance.open()
      try await adapters.waitForAll()
      #expect(wire.closed.isOpen)
      while let frame = await frames.next() { #expect(frame.opcode == .ack) }
    }
  }

  @Test func aRefusedDuplicateAdapterCannotStopTheAdmittedStreamOrDiscardItsQueuedOutput() async throws {
    let space = try makeMachineSpace()
    let machine = try await space.addMachineV2(name: "admission", group: .shared).machine.id
    let record = try await space.reserveExec(machine: machine, group: .shared)
    let cell = MachineCell.ID(machine.rawValue)
    let finish = Gate()
    let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(AdmissionProcess(finish: finish))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let first = AdmissionWire()
    let duplicate = AdmissionWire()
    defer { first.finish(); duplicate.finish(); finish.open() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      do {
        try await withMachineBox(space: space, hub: hub, machine: machine, client: FetchClient { try await agent.handler($0) }) {
          try await withThrowingTaskGroup(of: Void.self) { adapters in
            let bridge = ExecSocketLink(space: space, record: record, leg: .anonymous)
            adapters.addTask { await bridge.run(first.socket(blockAcceptance: true)) }
            defer { first.releaseAcceptance.open(); adapters.cancelAll() }
            var frames = first.outgoing.stream.makeAsyncIterator()
            #expect(try #require(await frames.next()).opcode == .control)
            first.send(Frame(streamID: 7, opcode: .execStart, payload: ExecStart(id: record.id, cwd: "/", command: ["admission-test"])))
            await first.acceptance.wait()
            while true {
              try Task.checkCancellation()
              let cursor = try await space.worker.call(cell) { $0.operation(record.id.rawValue)!.cursor }
              if cursor == AdmissionProcess.prefix.utf8.count { break }
            }

            // Block the accepted ACK so the first adapter has not read its queued output pointer yet.
            duplicate.send(Frame(streamID: 9, opcode: .execStart, payload: ExecStart(id: record.id, cwd: "/", command: ["admission-test"])))
            await bridge.run(duplicate.socket())
            #expect(duplicate.closed.isOpen)
            var rejected = duplicate.outgoing.stream.makeAsyncIterator()
            #expect(try #require(await rejected.next()).opcode == .control)
            #expect(await rejected.next() == nil)
            let untouched = try await space.worker.call(cell) { cell in
              let row = cell.operation(record.id.rawValue)!
              return row.stop == nil && !row.delivered && row.cursor == AdmissionProcess.prefix.utf8.count
            }
            #expect(untouched, "refusing the duplicate must not stop the admitted stream")
            #expect(!first.closed.isOpen)

            first.releaseAcceptance.open()
            finish.open()
            let accepted = try #require(await frames.next())
            #expect(accepted.opcode == .ack)
            var stdout = Data()
            var exit: ExecExit?
            while let frame = await frames.next() {
              #expect(frame.streamID == 7)
              if frame.opcode == .output {
                let output = try frame.payload(OutputChunk.self)
                #expect(output.stream == .stdout)
                #expect(output.cursor == stdout.count)
                stdout.append(contentsOf: output.data.bytes)
                first.send(Frame(streamID: 7, opcode: .ack, payload: Ack(id: record.id, cursor: output.cursor + output.data.bytes.count)))
              } else if frame.opcode == .execExit {
                exit = try frame.payload(ExecExit.self)
                first.send(Frame(streamID: 7, opcode: .ack, payload: Ack(id: record.id, cursor: exit!.cursor, terminal: true)))
                break
              } else { Issue.record("unexpected admitted stream frame: \(frame.opcode)") }
            }
            #expect(String(decoding: stdout, as: UTF8.self) == AdmissionProcess.prefix + AdmissionProcess.suffix)
            let ending = try #require(exit)
            #expect(ending.status == .exited(code: 0))
            #expect(ending.cursor == stdout.count)
            #expect(ending.outputCut != true)
            #expect(ending.timedOut == nil)
            try await adapters.waitForAll()
            #expect(first.closed.isOpen)
            #expect(try await space.execRecord(record.id)?.terminal == .exited(code: 0))
          }
        }
        await agent.shutdown()
      } catch {
        finish.open(); first.releaseAcceptance.open()
        await agent.shutdown()
        throw error
      }
    }
    try await space.close()
  }
}

private struct AdmissionProcess: OperationKind {
  static let prefix = "queued-before-refusal\n"
  static let suffix = "completed-after-refusal\n"
  let finish: Gate
  struct Input: Decodable, Sendable { let argv: [String] }
  let descriptor = ComputerKindSchemas.exec

  func start(_ input: Input, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    OperationStart { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    #expect(input.argv == ["admission-test"])
    try await channels.send(.init(data: Data(Self.prefix.utf8)), to: "stdout")
    do {
      try await cancellation.unlessStopped {
        await finish.wait()
        try Task.checkCancellation()
      }
    } catch is CancellationError {
      try Task.checkCancellation()
      return ["termination": ["tag": "signal", "signal": 15]]
    }
    try await channels.send(.init(data: Data(Self.suffix.utf8)), to: "stdout")
    return ["termination": ["tag": "exit", "code": 0]]
  }
}

private final class AdmissionWire: Sendable {
  let incoming = AsyncStream<WebSocketMessage>.makeStream()
  let outgoing = AsyncStream<Frame>.makeStream()
  let acceptance = Gate()
  let releaseAcceptance = Gate()
  let closed = Gate()

  func socket(blockAcceptance: Bool = false) -> WebSocket {
    WebSocket(inbound: incoming.stream, send: { [self] message in
      guard case let .binary(bytes) = message else { Issue.record("exec adapter sent a nonbinary frame"); return }
      let frame = try FrameCodec.decode(bytes)
      if blockAcceptance, frame.opcode == .ack {
        acceptance.open()
        await releaseAcceptance.wait()
        try Task.checkCancellation()
      }
      outgoing.continuation.yield(frame)
    }, close: { [self] in
      outgoing.continuation.finish(); closed.open()
    }, abort: { [self] in
      outgoing.continuation.finish(); closed.open()
    })
  }

  func send(_ frame: Frame) { incoming.continuation.yield(.binary(FrameCodec.encode(frame))) }
  func finish() { releaseAcceptance.open(); incoming.continuation.finish() }
}
