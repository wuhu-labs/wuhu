import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineChannel
import MachineContract
import OperationProtocol
import Serve
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct ExecSocketLinkTests {
  @Test func capacityRefusalKeepsTheWireOpenUntilItsTerminalAcknowledgement() async throws {
    let space = try makeMachineSpace()
    let machine = try await space.addMachineV2(name: "capacity", group: .shared).machine.id
    let record = try await space.reserveExec(machine: machine, group: .shared)
    let cell = MachineCell.ID(machine.rawValue)
    let described = Gate()
    let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
    let box = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 2)) {
      if case let .frame(frame) = $0, frame.tag == .describe { described.open() }
    })
    defer { box.close() }
    await described.wait()
    try Task.checkCancellation()
    box.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
    try await waitForMachineDescription(cell, in: space)

    let incoming = AsyncStream<WebSocketMessage>.makeStream()
    let outgoing = AsyncStream<Frame>.makeStream()
    let terminalSent = Mutex(false)
    let closed = Gate()
    let socket = WebSocket(inbound: incoming.stream, send: { message in
      guard case let .binary(bytes) = message else { Issue.record("exec wire sent a nonbinary frame"); return }
      outgoing.continuation.yield(try FrameCodec.decode(bytes))
    }, close: {
      if !Task.isCancelled { #expect(terminalSent.withLock { $0 }, "the adapter closed before a terminal acknowledgement") }
      outgoing.continuation.finish()
      closed.open()
    }, abort: {
      outgoing.continuation.finish()
      closed.open()
    })
    let bridge = ExecSocketLink(space: space, record: record, leg: .person(try await space.ensureDevPerson().account))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await bridge.run(socket) }
      defer { incoming.continuation.finish(); tasks.cancelAll() }
      var frames = outgoing.stream.makeAsyncIterator()
      let hello = try #require(await frames.next())
      #expect(hello.opcode == .control)
      incoming.continuation.yield(.binary(FrameCodec.encode(Frame(streamID: 7, opcode: .execStart, payload: ExecStart(id: record.id, cwd: "/", command: ["never-started"])))))
      let output = try #require(await frames.next())
      #expect(output.streamID == 7)
      #expect(output.opcode == .output)
      let diagnostic = try output.payload(OutputChunk.self)
      #expect(diagnostic.stream == .stderr)
      #expect(diagnostic.cursor == 0)
      #expect(String(decoding: diagnostic.data.bytes, as: UTF8.self) == "capacityExceeded: Machine exec tunnel capacity is full\n")
      let terminal = try #require(await frames.next())
      #expect(terminal.streamID == 7)
      #expect(terminal.opcode == .execExit)
      let exit = try terminal.payload(ExecExit.self)
      #expect(exit.cursor == diagnostic.data.bytes.count)
      #expect(exit.status == .exited(code: 1))
      #expect(!closed.isOpen)
      incoming.continuation.yield(.binary(FrameCodec.encode(Frame(streamID: 7, opcode: .ack, payload: Ack(id: record.id, cursor: exit.cursor)))))
      try await space.worker.call(cell) { _ in }
      #expect(!closed.isOpen)
      terminalSent.withLock { $0 = true }
      incoming.continuation.yield(.binary(FrameCodec.encode(Frame(streamID: 7, opcode: .ack, payload: Ack(id: record.id, cursor: exit.cursor, terminal: true)))))
      try await tasks.waitForAll()
      #expect(closed.isOpen)
      #expect(await frames.next() == nil)
    }
    try await space.close()
  }
}
