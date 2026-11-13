import ControlledTime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
import Scratch
@testable import SpaceCore
import Testing
import Wuwei
import WuweiQueries

@Suite struct MachineCellTests {
  let cell = MachineCell.ID("test-machine")
  let recipient = Recipient<MachineExecReply>(kind: "test-recipient", key: "exec")

  func setup(_ space: Space) -> MachineBuffers {
    let buffers = space.machineBuffers
    space.worker.start()
    return buffers
  }

  func attach(_ space: Space, _ requests: Box<[BoxSocket.Outgoing]>) async throws -> Peer<BoxSocket> {
    let pubkey = try await seedBoxKey(space: space, machine: cell.key)
    return try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { requests.withLock { $0.append(frame) } }
    })
  }

  func advance(_ time: TimeControl, by seconds: Int, in space: Space) async throws {
    for _ in 0 ..< seconds {
      await time.advance(by: 1)
      _ = try await space.worker.call(cell) { _ in true }
    }
  }

  var description: MachineDescription { .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]) }
  func described(_ peer: Peer<BoxSocket>, _ space: Space) async throws {
    peer.send(.init(tag: .describe, answer: .description(description)))
    try await until("describe commits") { space.worker.cell(cell).db.rows(MachinePresence.all).first?.state == "attached" }
  }

  func starting(_ space: Space, _ peer: Peer<BoxSocket>, _ request: MachineExec) async throws {
    try await space.worker.call(cell) { try $0.start(request, finished: recipient) }
    try await until("start intent commits") { space.worker.cell(cell).operation(request.id)?.dispatched == true }
    peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: snapshot(request)))))
    try await until("start answer commits") { space.worker.cell(cell).operation(request.id)?.state == "running" }
  }

  func snapshot(_ exec: MachineExec, channel: String? = nil, from: UInt64? = nil, through: UInt64? = nil, verdict: Verdict? = nil, finals: [String: Offset] = [:]) -> OperationSnapshot {
    .init(operation: exec.operation, verdict: verdict, terminalToken: verdict == nil ? nil : UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, finalOffsets: verdict == nil ? finals : ["stdout": .zero, "stderr": .zero].merging(finals) { _, final in final }, outputConsumed: false, channel: channel, from: from.map { .init(rawValue: $0) }, through: through.map { .init(rawValue: $0) })
  }

  @Test func `poll commits before ack and a repeated range changes nothing`() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-cell")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "exec-one", operation: UUID(), createdAt: anchor.addingTimeInterval(-120), group: .shared, argv: ["echo", "one"])
      try await starting(space, peer, exec)
      let dispatched = try #require(requests.value.compactMap { if case let .start(value) = $0.exchange { value } else { nil } }.first)
      #expect(dispatched.createdAt == exec.createdAt)
      let bytes = Data("one\n".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let frame = BoxSocket.Incoming(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 4), output: pointer, tail: bytes)))
      peer.send(frame)
      try await until("output commits") { space.worker.cell(cell).operation(exec.id)?.stdout == 4 }
      try await until("committed offset is acked") { requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 4 } else { false } } }
      peer.send(frame)
      _ = try await space.worker.call(cell) { $0.tail(exec.id) }
      #expect(space.worker.cell(cell).operation(exec.id)?.cursor == 4)
      #expect(space.worker.cell(cell).tail(exec.id) == bytes)
      peer.close()
      try await space.close()
    }
  }

  @Test func `finished mail retains the tail until taken`() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-cell")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      let buffers = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "exec-end", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo", "done"])
      try await starting(space, peer, exec)
      let bytes = Data("done".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 4, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), finals: ["stdout": .init(rawValue: 4)]), output: pointer, tail: bytes))))
      try await until("end is delivered") { space.worker.cell(cell).operation(exec.id)?.delivered == true }
      #expect(space.worker.cell(cell).tail(exec.id) == bytes)
      try await space.worker.call(cell) { try $0.taken(exec.id) }
      #expect(space.worker.cell(cell).tail(exec.id).isEmpty)
      let mails = try RawDatabase.open(space.databasePath) {
        try $0.rows("SELECT payload FROM wuwei_mail WHERE recipient = 'test-recipient/exec'").map { row in
          let payload: Data = row[0]
          return payload
        }
      }
      #expect(mails.count == 1)
      guard case let .finished(end) = try JSONDecoder().decode(MachineExecReply.self, from: #require(mails.first)) else { return }
      #expect(end.tail == bytes)
      #expect(end.status == .exited(code: 0))
      peer.close()
      try await space.close()
    }
  }

  @Test func `unopened reservations reap on the injected clock and kill precedes start`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("machine-cell")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      let exec = MachineExec(id: "reserved", operation: UUID(), createdAt: anchor, group: .shared)
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      try await time.asleep("unopened reservation deadline", dueIn: 60)
      try await advance(time, by: 60, in: space)
      try await until("unopened reservation reaps") { space.worker.cell(cell).operation(exec.id)?.terminal == true }
      let killed = MachineExec(id: "killed", operation: UUID(), createdAt: anchor, group: .shared)
      _ = try await space.worker.call(cell) { try $0.reserve(killed) }
      try await space.worker.call(cell) { try $0.stop(killed.id) }
      #expect(space.worker.cell(cell).operation(killed.id)?.dispatched == false)
      #expect(space.worker.cell(cell).operation(killed.id)?.terminal == true)
      try await space.close()
    }
  }

  @Test func `transport errors never renew the box lease`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("machine-cell")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let lease = space.worker.cell(cell).presence.lease
      try await advance(time, by: 10, in: space)
      peer.send(.init(tag: .describe, answer: .transport(.init(.transport))))
      _ = try await space.worker.call(cell) { _ in true }
      #expect(space.worker.cell(cell).presence.lease == lease)
      try await advance(time, by: 50, in: space)
      try await until("lease silence marks lost") { space.worker.cell(cell).presence.state == "lost" }
      try await space.close()
    }
  }

  @Test func `delete leaves a tombstone and completes each waiter once`() async throws {
    try await withKernelDeps { _ in
      let folder = try ScratchFolder("machine-cell")
      let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
      _ = setup(space)
      _ = try await seedBoxKey(space: space, machine: cell.key)
      let exec = MachineExec(id: "deleted", operation: UUID(), createdAt: anchor, group: .shared)
      try await space.worker.call(cell) { try $0.start(exec, finished: recipient) }
      try await space.worker.call(cell) { try $0.delete(in: .shared) }
      #expect(space.worker.cell(cell).operation(exec.id) == nil)
      #expect(space.worker.cell(cell).presence.state == "deleted")
      let count = try RawDatabase.open(space.databasePath) { try $0.int("SELECT count(*) FROM wuwei_mail WHERE recipient = 'test-recipient/exec'") }
      #expect(count == 1)
      await #expect(throws: OperationError.self) { try await space.worker.call(cell) { try $0.reserve(exec) } }
      try await space.close()
    }
  }
}
