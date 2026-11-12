#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import GRDB
import OperationProtocol
import Scratch
@testable import SpaceCore
import Testing
import Wuwei

private struct Rollback: Error {}

extension MachineCellTests {
  @Test func `a failed poll step retains bytes and repeats from its committed offset`() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-rollback")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "rollback", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"], maxOutput: 3)
      try await starting(space, peer, exec)
      let bytes = Data("abcdef".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let frame = BoxSocket.Incoming(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 6), output: pointer, tail: bytes)))
      await #expect(throws: Rollback.self) {
        try await space.worker.call(cell) { cell in
          let socket = cell.ctx.sockets(of: BoxSocket.self).last!
          try cell.answer(frame, from: socket)
          throw Rollback()
        }
      }
      #expect(space.worker.cell(cell).operation(exec.id)?.stdout == 0)
      #expect(space.worker.cell(cell).tail(exec.id).isEmpty)
      #expect(buffers.read(pointer) == bytes)
      #expect(!requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after > 0 } else { false } })
      peer.send(frame)
      try await until("retried output commits") { space.worker.cell(cell).operation(exec.id)?.stdout == 6 }
      #expect(space.worker.cell(cell).tail(exec.id) == Data("abc".utf8))
      #expect(space.worker.cell(cell).operation(exec.id)?.cursor == 3)
      #expect(space.worker.cell(cell).operation(exec.id)?.stop == "outputLimit")
      peer.send(frame)
      _ = try await space.worker.call(cell) { _ in true }
      #expect(space.worker.cell(cell).operation(exec.id)?.cursor == 3)
      peer.close()
      try await space.close()
    }
  }

  @Test func `timeout stops the exec and answers after thirty more seconds`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("machine-timeout")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "timeout", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"], timeout: 1)
      try await starting(space, peer, exec)
      await time.advance(by: 1)
      try await until("timeout stop is emitted") { requests.value.contains { if case let .stop(op, reason) = $0.exchange { op == exec.operation && reason == "timeout" } else { false } } }
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == false)
      try await advance(time, by: 30, in: space)
      try await until("answer grace expires") { space.worker.cell(cell).operation(exec.id)?.delivered == true }
      #expect(space.worker.cell(cell).operation(exec.id)?.diagnostic?.code == .requestDeadline)
      #expect(space.worker.cell(cell).result(space.worker.cell(cell).operation(exec.id)!).timedOut == .statusUnknown)
      try await space.close()
    }
  }

  @Test func `retry backoff waits on the injected clock`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("machine-backoff")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let exec = MachineExec(id: "backoff", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"])
      let stdoutTag = BoxTag.operation(exec.operation, .output("stdout"))
      let emissions = AsyncStream<Void>.makeStream()
      defer { emissions.continuation.finish() }
      let pubkey = try await seedBoxKey(space: space, machine: cell.key)
      let peer = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
        if case let .frame(frame) = $0 {
          requests.withLock { $0.append(frame) }
          if frame.tag == stdoutTag { emissions.continuation.yield(()) }
        }
      })
      try await described(peer, space)
      try await starting(space, peer, exec)
      var emitted = emissions.stream.makeAsyncIterator()
      try #require(await emitted.next() != nil)
      let count = requests.value.filter { $0.tag == stdoutTag }.count
      #expect(count == 1)
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .transport(.init(.transport))))
      _ = try await space.worker.call(cell) { _ in true }
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.output("stdout")]?.waiting == false)
      await time.advance(by: 0.05)
      #expect(requests.value.filter { $0.tag == .operation(exec.operation, .output("stdout")) }.count == count)
      await time.advance(by: 0.05)
      try await until("backoff retry is emitted") { requests.value.filter { $0.tag == stdoutTag }.count == count + 1 }
      peer.close()
      try await space.close()
    }
  }

  @Test(arguments: [65536, 131_072]) func `stream backpressure pauses polls and consumed resumes before close stops`(_ pollBytes: Int) async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-stream")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      var limits = OperationLimits()
      limits.pollBytes = pollBytes
      peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [ComputerKindSchemas.exec]))))
      try await until("stream description commits") { space.worker.cell(cell).db.rows(MachinePresence.all).first?.state == "attached" }
      let exec = MachineExec(id: "stream", operation: UUID(), createdAt: anchor, group: .shared, argv: ["cat"], window: 131_072)
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      let outputs = Box<[ExecStream.Outgoing]>([])
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) { if case let .frame(frame) = $0 { outputs.withLock { $0.append(frame) } } })
      try await until("stream start commits") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      peer.send(.init(tag: .operation(exec.operation, .start), answer: .snapshot(.init(snapshot: snapshot(exec)))))
      try await until("stream start answers") { space.worker.cell(cell).operation(exec.id)?.state == "running" }
      try await until("poll fits the caller window") { requests.value.contains { if case let .poll(_, channel, _, _, _, limit) = $0.exchange { channel == "stdout" && limit == 65536 } else { false } } }
      let bytes = Data(repeating: 65, count: 65536)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 65536), output: pointer, tail: bytes.suffix(51200)))))
      try await until("stream output emits") { outputs.value.contains { if case .output = $0 { true } else { false } } }
      #expect(!requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 65536 } else { false } })
      stream.send(.consumed(65536))
      try await until("consumed resumes polling") { requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 65536 } else { false } } }
      stream.close()
      try await until("stream close emits stop") { requests.value.contains { if case let .stop(_, reason) = $0.exchange { reason == "callerGone" } else { false } } }
      peer.close()
      try await space.close()
    }
  }

  @Test func `interrupt after a stranded finish clears the waiter without a session notice`() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-interrupt")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "interrupted", operation: UUID(), createdAt: anchor, group: .shared, session: .init(rawValue: "test-session"), argv: ["sleep"])
      try await starting(space, peer, exec)
      peer.send(.init(tag: .operation(exec.operation, .control), answer: .snapshot(.init(snapshot: snapshot(exec, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]))))))
      try await until("finished is stranded") { space.worker.cell(cell).operation(exec.id)?.delivered == true }
      try await space.worker.call(cell) { try $0.abandon(exec.id) }
      #expect(space.worker.cell(cell).operation(exec.id)?.recipient == nil)
      #expect(space.worker.cell(cell).tail(exec.id).isEmpty)
      let count = try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM wuwei_mail WHERE recipient = 'SessionCell/test-session'") }
      #expect(count == 0)
      peer.close()
      try await space.close()
    }
  }
}

extension MachineCellTests {
  @Test func `a published verdict waits for both final output offsets`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "published", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      try await starting(space, peer, exec)
      let verdict = Verdict(.completed, result: ["termination": ["tag": "exit", "code": 0]])
      let token = UUID()
      let published = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: [:], outputConsumed: false)
      peer.send(.init(tag: .operation(exec.operation, .control), answer: .snapshot(.init(snapshot: published))))
      try await until("published verdict commits") { space.worker.cell(cell).operation(exec.id)?.snapshot?.verdict != nil }
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == false)
      #expect(!requests.value.contains { if case .operation(_, .terminal) = $0.tag { true } else { false } })
      let bytes = Data("late".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let stdout = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: ["stdout": .init(rawValue: 4)], outputConsumed: false, channel: "stdout", from: .zero, through: .init(rawValue: 4))
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: stdout, output: pointer, tail: bytes))))
      try await until("late stdout commits") { space.worker.cell(cell).operation(exec.id)?.stdout == 4 }
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == false)
      let stderr = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: ["stdout": .init(rawValue: 4), "stderr": .zero], outputConsumed: false, channel: "stderr", from: .zero, through: .zero)
      peer.send(.init(tag: .operation(exec.operation, .output("stderr")), answer: .snapshot(.init(snapshot: stderr))))
      try await until("all final offsets finish") { space.worker.cell(cell).operation(exec.id)?.delivered == true }
      #expect(space.worker.cell(cell).tail(exec.id) == bytes)
      peer.close()
      try await space.close()
    }
  }

  @Test func `retirement waits for both terminal channel acknowledgments`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "terminal-acks", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      try await starting(space, peer, exec)
      let verdict = Verdict(.completed, result: ["termination": ["tag": "exit", "code": 0]])
      let terminal = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: UUID(), finalOffsets: ["stdout": .zero, "stderr": .zero], outputConsumed: true)
      peer.send(.init(tag: .operation(exec.operation, .control), answer: .snapshot(.init(snapshot: terminal))))
      try await until("both terminal polls emit") { requests.value.contains { $0.tag == .operation(exec.operation, .terminal("stderr")) } }
      peer.send(.init(tag: .operation(exec.operation, .terminal("stderr")), answer: .transport(.init(.transport))))
      peer.send(.init(tag: .operation(exec.operation, .terminal("stdout")), answer: .snapshot(.init(snapshot: terminal))))
      try await until("stdout terminal acknowledgment commits") { space.worker.cell(cell).operation(exec.id)?.terminalAcks == ["stdout"] }
      #expect(space.worker.cell(cell).operation(exec.id)?.terminal == false)
      await time.advance(by: 0.1)
      try await until("stderr terminal acknowledgment retries") { requests.value.filter { $0.tag == .operation(exec.operation, .terminal("stderr")) }.count == 2 }
      #expect(requests.value.filter { $0.tag == .operation(exec.operation, .terminal("stdout")) }.count == 2)
      peer.send(.init(tag: .operation(exec.operation, .terminal("stderr")), answer: .snapshot(.init(snapshot: terminal))))
      try await until("both acknowledgments retire") { space.worker.cell(cell).operation(exec.id)?.terminal == true }
      peer.close()
      try await space.close()
    }
  }

  @Test func `a terminal snapshot without its acknowledgment token is invalid`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      _ = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "invalid-terminal", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      try await starting(space, peer, exec)
      let invalid = OperationSnapshot(operation: exec.operation, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), terminalToken: nil, finalOffsets: [:], outputConsumed: false)
      peer.send(.init(tag: .operation(exec.operation, .control), answer: .snapshot(.init(snapshot: invalid))))
      try await until("malformed terminal is answered") { space.worker.cell(cell).operation(exec.id)?.diagnostic?.code == .invalidResponse }
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == true)
      peer.close()
      try await space.close()
    }
  }

  @Test func `starts admitted before describe cannot exceed tunnel capacity`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let pubkey = try await seedBoxKey(space: space, machine: cell.key)
      let peer = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 5)) {
        if case let .frame(frame) = $0 { requests.withLock { $0.append(frame) } }
      })
      try await until("box attach commits before pending starts") { requests.value.contains { $0.tag == .describe } }
      for index in 0 ..< 2 {
        let exec = MachineExec(id: "pending-\(index)", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"])
        try await space.worker.call(cell) { try $0.start(exec, finished: recipient) }
      }
      try await described(peer, space)
      try await until("one pending start is refused") {
        space.worker.cell(cell).db.rows(MachineOperation.all).filter { $0.diagnostic?.code == .capacityExceeded }.count == 1
      }
      #expect(requests.value.filter { if case .start = $0.exchange { true } else { false } }.count == 1)
      peer.close()
      try await space.close()
    }
  }
}
