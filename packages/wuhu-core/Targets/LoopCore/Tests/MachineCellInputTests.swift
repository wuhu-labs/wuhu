#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ControlledTime
import Dependencies
import OperationProtocol
@testable import SpaceCore
import Testing
import Wuwei

extension MachineCellTests {
  @Test func `stdin receipts advance before buffer cleanup and preserve queued eof`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "stdin", operation: UUID(), createdAt: anchor, group: .shared, argv: ["cat"])
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      let accepted = Box<[UInt64]>([])
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) {
        if case let .frame(.accepted(offset)) = $0 { accepted.withLock { $0.append(offset) } }
      })
      try await until("stdin stream starts") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      peer.send(.init(tag: .operation(exec.operation, .start), answer: .snapshot(.init(snapshot: snapshot(exec)))))
      try await until("stdin stream runs") { space.worker.cell(cell).operation(exec.id)?.state == "running" }
      let pointer = try #require(buffers.put(Data("abc".utf8), operation: exec.operation, channel: "stdin", from: 0))
      stream.send(.stdin(pointer))
      stream.send(.eof(3))
      let inputs = { requests.value.compactMap { request -> (MachinePointer, Bool)? in
        if case let .input(_, pointer, end) = request.exchange { return (pointer, end) }
        return nil
      } }
      try await until("first input emits") { inputs().count == 1 }
      peer.send(.init(tag: .operation(exec.operation, .input), answer: .input(.init(acceptedThrough: .init(rawValue: 1), end: false, blocked: false))))
      try await until("partial receipt emits only remaining input") { inputs().count == 2 }
      let rest = inputs()[1]
      #expect(rest.0.from == 1 && rest.0.through == 3 && !rest.1)
      #expect(buffers.read(rest.0) == Data("bc".utf8))
      let partialReplayAcks = accepted.value.count
      let partialReplay = try #require(buffers.put(Data("abc".utf8), operation: exec.operation, channel: "stdin", from: 0))
      stream.send(.stdin(partialReplay))
      try await until("partly accepted input replay acknowledges without closing") { accepted.value.count > partialReplayAcks }
      #expect(space.worker.cell(cell).operation(exec.id)?.stop == nil)
      #expect(inputs().count == 2)
      peer.send(.init(tag: .operation(exec.operation, .input), answer: .input(.init(acceptedThrough: .init(rawValue: 3), end: false, blocked: false))))
      try await until("accepted data emits queued eof") { inputs().count == 3 }
      try await until("accepted replay clone releases") { buffers.read(partialReplay) == nil }
      let eof = inputs()[2]
      #expect(eof.0.from == 3 && eof.0.through == 3 && eof.1)
      #expect(buffers.read(eof.0) == Data())
      let duplicate = try #require(buffers.put(Data("abc".utf8), operation: exec.operation, channel: "stdin", from: 0))
      let replayAcks = accepted.value.count
      stream.send(.stdin(duplicate))
      try await until("fully accepted replay acknowledges without closing") { accepted.value.count > replayAcks }
      #expect(space.worker.cell(cell).operation(exec.id)?.stop == nil)
      peer.send(.init(tag: .operation(exec.operation, .input), answer: .input(.init(acceptedThrough: .init(rawValue: 3), end: false, blocked: false))))
      try await until("duplicate data receipt enters bounded retry") { space.worker.cell(cell).operation(exec.id)?.flights[.input]?.waiting == false }
      #expect(inputs().count == 3)
      await time.advance(by: 0.1)
      try await until("duplicate data receipt retains eof") { inputs().count == 4 }
      #expect(inputs()[3].0 == eof.0 && inputs()[3].1)
      #expect(buffers.read(eof.0) == Data())
      peer.send(.init(tag: .operation(exec.operation, .input), answer: .input(.init(acceptedThrough: .init(rawValue: 3), end: true, blocked: false))))
      try await until("eof receipt commits and releases input") { space.worker.cell(cell).operation(exec.id)?.stdinEnded == true && buffers.read(eof.0) == nil }
      #expect(inputs().count == 4)
      let eofReplayAcks = accepted.value.count
      stream.send(.eof(3))
      try await until("accepted eof replay only acknowledges") { accepted.value.count > eofReplayAcks }
      #expect(inputs().count == 4)
      stream.close(); peer.close()
      try await space.close()
    }
  }
}

extension MachineCellTests {
  @Test func `a delivered stream keeps queued output readable until its adapter finishes`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "stream-end", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      let events = Box<[ExecStream.Outgoing]>([])
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) {
        if case let .frame(event) = $0 { events.withLock { $0.append(event) } }
      })
      try await until("finishing stream starts") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      peer.send(.init(tag: .operation(exec.operation, .start), answer: .snapshot(.init(snapshot: snapshot(exec)))))
      try await until("finishing stream runs") { space.worker.cell(cell).operation(exec.id)?.state == "running" }
      let bytes = Data("done".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let frame = BoxSocket.Incoming(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 4, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), finals: ["stdout": .init(rawValue: 4)]), output: pointer, tail: bytes)))
      try await space.worker.call(cell) { cell in
        let stream = try #require(cell.ctx.sockets(of: ExecStream.self).first)
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(frame, from: box)
        try cell.drive()
        #expect(cell.operation(exec.id)?.delivered == true)
        try cell.closeStream(stream)
      }
      try await until("finishing stream exit queues") { events.value.contains { if case .exit = $0 { true } else { false } } }
      #expect(buffers.read(pointer) == bytes)
      #expect(events.value.contains { if case let .output(value, _) = $0 { value == pointer } else { false } })
      buffers.discard(exec.operation)
      #expect(buffers.read(pointer) == nil)
      stream.close(); peer.close()
      try await space.close()
    }
  }
}

extension MachineCellTests {
  @Test(arguments: [0.0, -1.0]) func `invalid timeout is refused before a credential can be minted`(_ timeout: Double) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "invalid-timeout", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"], timeout: timeout)
      do { _ = try await space.worker.call(cell) { try $0.reserve(exec) }; Issue.record("invalid reservation admitted") }
      catch let error as OperationError { #expect(error.code == .invalidInput) }
      try await space.worker.call(cell) { try $0.start(exec, finished: recipient) }
      let row = try #require(space.worker.cell(cell).operation(exec.id))
      #expect(row.terminal && row.delivered && !row.dispatched)
      #expect(row.diagnostic?.code == .invalidInput)
      #expect(!requests.value.contains { if case .start = $0.exchange { true } else { false } })
      try await space.worker.call(cell) { try $0.taken(exec.id) }
      peer.close()
      try await space.close()
    }
  }
}
