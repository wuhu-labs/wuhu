#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ControlledTime
import Dependencies
import Dispatch
import GRDB
import OperationProtocol
@testable import SpaceCore
import Testing
@testable import Wuwei
import WuweiQueries

private func tracedMachineSpace(_ statements: Box<[String]>) throws -> Space {
  var configuration = Space.makeConfiguration(journalMode: .default)
  configuration.prepareDatabase { db in
    db.trace { event in
      if case let .statement(statement) = event {
        statements.withLock { $0.append(statement.expandedSQL) }
      }
    }
  }
  return try Space.inMemory(configuration: configuration)
}

extension MachineCellTests {
  @Test func aFrameReadsOneLiveRowPerQueryRegardlessOfRetiredHistory() async throws {
    try await withKernelDeps { _ in
      let statements = Box<[String]>([])
      let space = try tracedMachineSpace(statements)
      let buffers = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "id-unrelated-to-wire-uuid", operation: UUID(), createdAt: anchor, group: .shared, caller: "caller", toolCall: .init("live-call"), script: "script", argv: ["echo"])
      try await starting(space, peer, exec)
      let retired = 256
      try await space.worker.call(cell) { cell in
        for index in 0 ..< retired {
          let request = MachineExec(id: "retired-\(index)", operation: UUID(), createdAt: anchor, group: .shared, caller: "caller", toolCall: .init("retired-\(index)"), script: "script")
          var row = MachineOperation(id: request.id, request: request, created: cell.now)
          row.state = "retired"; row.delivered = true; row.opened = true
          try cell.save(row)
        }
      }
      let bytes = Data("live".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      statements.withLock { $0 = [] }
      try await space.worker.call(cell) { cell in
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 4), output: pointer, tail: bytes))), from: box)
      }
      let frameReads = statements.value.filter { $0.hasPrefix("SELECT") && $0.contains("\"machine_operations\"") }
      #expect(frameReads.count == 3)
      let measures = try await space.writer.read { db in
        try frameReads.map { sql in
          let sql = sql.replacingOccurrences(of: "cell()", with: "'test-machine'")
          return (
            try Row.fetchAll(db, sql: sql).count,
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: "\n"),
          )
        }
      }
      // Replaying the traced frame's SELECTs measures hydrated rows, not SQLite VM instructions.
      print("MachineCell rows/frame: \(measures.map(\.0)); total=\(measures.reduce(0) { $0 + $1.0 }); retired=\(retired)")
      print("MachineCell frame query plans: \(measures.map(\.1))")
      #expect(measures.map(\.0) == [1, 1, 1])
      #expect(measures.first?.1.contains("machine_operations_operation") == true)
      #expect(measures.dropFirst().allSatisfy { $0.1.contains("machine_operations_live") })
      #expect(space.worker.cell(cell).operation(exec.id)?.stdout == 4)
      #expect(space.worker.cell(cell).tail(exec.id) == bytes)
      #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM machine_operations WHERE state = 'retired'") } == retired)

      let record = try #require(try await space.execRecord(caller: "caller", toolCallID: .init("live-call")))
      #expect(try await space.liveExecs() == [record])
      #expect(try await space.liveToolExecs(caller: "caller") == [record])
      #expect(try await space.liveScriptExecs(script: "script", caller: "caller") == [record.id])
      #expect(try await space.execRecord(caller: "caller", toolCallID: .init("retired-0"))?.terminal != nil)
      peer.close()
      try await space.close()
    }
  }

  @Test func aDescriptionWithoutExecFinishesDispatchedOperationsInItsOwnStep() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      _ = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "kind-removed", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"])
      try await starting(space, peer, exec)
      let missing = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      try await space.worker.call(cell) { cell in
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(.init(tag: .describe, answer: .description(missing)), from: box)
        let row = try #require(cell.operation(exec.id))
        #expect(row.terminal && row.delivered)
        #expect(row.diagnostic?.code == .unknownKind)
      }
      peer.send(.init(tag: .describe, answer: .description(missing)))
      _ = try await space.worker.call(cell) { _ in true }
      #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM wuwei_mail WHERE recipient = 'test-recipient/exec'") } == 1)
      peer.close()
      try await space.close()
    }
  }

  @Test func closingARejectedSecondStreamLeavesTheAdmittedStreamAndItsBytesIntact() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "stream-owner", operation: UUID(), createdAt: anchor, group: .shared, argv: ["cat"])
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      let events = Box<[ExecStream.Outgoing]>([])
      @Dependency(\.uuid) var uuid
      let first = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) {
        if case let .frame(frame) = $0 { events.withLock { $0.append(frame) } }
      })
      try await until("the admitted stream starts") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      peer.send(.init(tag: .operation(exec.operation, .start), answer: .snapshot(.init(snapshot: snapshot(exec)))))
      try await until("the admitted stream runs") { space.worker.cell(cell).operation(exec.id)?.state == "running" }
      let bytes = Data("kept".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let secondEvents = Box<[ExecStream.Outgoing]>([])
      let secondNonce = uuid()
      let second = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: secondNonce)) {
        if case let .frame(frame) = $0 { secondEvents.withLock { $0.append(frame) } }
      })
      try await space.worker.call(cell) { cell in
        let admitted = try #require(cell.ctx.sockets(of: ExecStream.self).first)
        let rejected = SocketHandle<ExecStream>(attachment: second.attachment, reach: admitted.reach)
        try cell.openStream(rejected)
        try cell.closeStream(rejected)
        #expect(cell.operation(exec.id)?.stop == nil)
      }
      #expect(buffers.read(pointer) == bytes)
      #expect(secondEvents.value.isEmpty)
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 4), output: pointer, tail: bytes))))
      try await until("the first stream still receives output") { events.value.contains { if case let .output(value, _) = $0 { value == pointer } else { false } } }
      first.close(); peer.close()
      try await space.close()
    }
  }

  @Test func aTimeoutBeforeDispatchFinishesWithoutEverStartingTheBoxProcess() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await until("box attaches without a description") { requests.value.contains { $0.tag == .describe } }
      let exec = MachineExec(id: "pending-timeout", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"], timeout: 1)
      try await space.worker.call(cell) { try $0.start(exec, finished: recipient) }
      #expect(space.worker.cell(cell).operation(exec.id)?.dispatched == false)
      await time.advance(by: 1)
      try await space.worker.call(cell) { try $0.wake() }
      let row = try #require(space.worker.cell(cell).operation(exec.id))
      #expect(row.terminal && row.delivered && !row.dispatched)
      #expect(row.stop == "timeout")
      #expect(row.answerAt == nil)
      try await described(peer, space)
      #expect(!requests.value.contains { if case .start = $0.exchange { true } else { false } })
      #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM wuwei_mail WHERE recipient = 'test-recipient/exec'") } == 1)
      peer.close()
      try await space.close()
    }
  }

  @Test func outputFrameStepMedianWithOneLiveExec() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let peer = try await attach(space, Box([]))
      try await described(peer, space)
      let exec = MachineExec(id: "frame-median", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      try await starting(space, peer, exec)
      let bytes = Data(repeating: 65, count: 16384)
      var samples: [UInt64] = []
      for index in 0 ..< 19 {
        let from = UInt64(index * bytes.count)
        let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: from))
        let frame = BoxSocket.Incoming(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: from, through: from + UInt64(bytes.count)), output: pointer, tail: bytes)))
        let began = DispatchTime.now().uptimeNanoseconds
        try await space.worker.call(cell) { cell in
          let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
          try cell.answer(frame, from: box)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        if index >= 4 { samples.append(elapsed) }
      }
      let statements = Box<[String]>([])
      try await space.writer.writeWithoutTransaction { db in
        db.trace { event in
          if case let .statement(statement) = event { statements.withLock { $0.append(statement.expandedSQL) } }
        }
      }
      let from = UInt64(19 * bytes.count)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: from))
      let frame = BoxSocket.Incoming(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: from, through: from + UInt64(bytes.count)), output: pointer, tail: bytes)))
      try await space.worker.call(cell) { cell in
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(frame, from: box)
      }
      try await space.writer.writeWithoutTransaction { $0.trace() }
      let presenceReads = statements.value.filter { $0.hasPrefix("SELECT") && $0.contains("\"machine_presence\"") }.count
      let median = samples.sorted()[samples.count / 2]
      print("MachineCell one-live-exec output-frame step median: \(median) ns; timed frames=\(samples.count); payload=16384; warmups=4; presence SELECTs/frame=\(presenceReads)")
      peer.close()
      try await space.close()
    }
  }
}
