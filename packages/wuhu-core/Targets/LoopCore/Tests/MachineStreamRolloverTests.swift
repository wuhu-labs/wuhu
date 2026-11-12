import Dependencies
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

extension MachineCellTests {
  @Test func replacementWorkerDoesNotRouteOrphanIntoReusedSocketID() async throws {
    try await withKernelDeps { _ in
      @Dependency(\.uuid) var uuid
      let xNonce = uuid(), yNonce = uuid()
      #expect(xNonce != yNonce)
      let folder = try ScratchFolder("stream-socket-rollover")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      _ = setup(old)
      let oldBox = try await attach(old, Box([]))
      try await described(oldBox, old)
      let x = MachineExec(id: "orphan-x", operation: UUID(), createdAt: anchor, group: .shared, argv: ["x"])
      _ = try await old.worker.call(cell) { try $0.reserve(x) }
      let oldEvents = Box<[ExecStream.Outgoing]>([])
      let oldCloses = Box(0)
      let oldStream = try #require(old.worker.attach(ExecStream.self, to: cell, opening: .init(exec: x, nonce: xNonce)) {
        switch $0 {
        case let .frame(event): oldEvents.withLock { $0.append(event) }
        case .closed: oldCloses.withLock { $0 += 1 }
        }
      })
      try await until("X is dispatched by the first worker") { old.worker.cell(cell).operation(x.id)?.dispatched == true }
      oldBox.send(.init(tag: .operation(x.operation, .start), answer: .snapshot(.init(snapshot: snapshot(x)))))
      try await until("X is running before rollover") { old.worker.cell(cell).operation(x.id)?.state == "running" }
      let oldID = try await old.worker.call(cell) { cell in
        try #require(cell.ctx.sockets(of: ExecStream.self).first).id
      }
      #expect(oldID == 2)
      await old.stopWorker()
      try await until("the abandoned X socket closes once") { oldCloses.value == 1 }

      let buffers = setup(new)
      let attached = AsyncStream<Void>.makeStream()
      let pubkey = try await seedBoxKey(space: new, machine: cell.key)
      let newBox = try #require(new.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: uuid(), pubkey: pubkey, streams: 32)) {
        if case let .frame(request) = $0, case .describe = request.tag {
          attached.continuation.yield(); attached.continuation.finish()
        }
      })
      for await _ in attached.stream { break }
      try await described(newBox, new)
      #expect(new.worker.cell(cell).operation(x.id)?.stream == nil)
      let y = MachineExec(id: "new-y", operation: UUID(), createdAt: anchor, group: .shared, argv: ["y"])
      _ = try await new.worker.call(cell) { try $0.reserve(y) }
      let events = Box<[ExecStream.Outgoing]>([])
      let closes = Box(0)
      let newStream = try #require(new.worker.attach(ExecStream.self, to: cell, opening: .init(exec: y, nonce: yNonce)) {
        switch $0 {
        case let .frame(event): events.withLock { $0.append(event) }
        case .closed: closes.withLock { $0 += 1 }
        }
      })
      try await until("Y is dispatched before X settles") { new.worker.cell(cell).operation(y.id)?.dispatched == true }
      let reusedID = try await new.worker.call(cell) { cell in
        try #require(cell.ctx.sockets(of: ExecStream.self).first).id
      }
      #expect(reusedID == oldID)
      newBox.send(.init(tag: .operation(y.operation, .start), answer: .snapshot(.init(snapshot: snapshot(y)))))
      try await until("Y is running") { new.worker.cell(cell).operation(y.id)?.state == "running" }
      #expect(new.worker.cell(cell).operation(x.id)?.delivered == false)

      let xBytes = Data("X-only".utf8)
      let xPointer = try #require(buffers.put(xBytes, operation: x.operation, channel: "stdout", from: 0))
      let xAnswer = BoxSocket.Incoming(tag: .operation(x.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(x, channel: "stdout", from: 0, through: UInt64(xBytes.count), verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 23]]), finals: ["stdout": .init(rawValue: UInt64(xBytes.count))]), output: xPointer, tail: xBytes)))
      newBox.send(xAnswer)
      try await until("X's final answer settles") { new.worker.cell(cell).operation(x.id)?.delivered == true }
      #expect(events.value.allSatisfy { if case .accepted = $0 { true } else { false } }, "Y must receive neither X's bytes nor its exit")
      #expect(closes.value == 0, "X's finish must not close Y's reused socket")
      #expect(new.worker.cell(cell).operation(y.id)?.stop == nil)

      let yBytes = Data("Y-only".utf8)
      let yPointer = try #require(buffers.put(yBytes, operation: y.operation, channel: "stdout", from: 0))
      newBox.send(.init(tag: .operation(y.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(y, channel: "stdout", from: 0, through: UInt64(yBytes.count), verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 7]]), finals: ["stdout": .init(rawValue: UInt64(yBytes.count))]), output: yPointer, tail: yBytes))))
      try await until("Y delivers and closes exactly once") { new.worker.cell(cell).operation(y.id)?.delivered == true && closes.value == 1 }
      let outputs = events.value.compactMap { event -> MachinePointer? in
        if case let .output(pointer, _) = event { pointer } else { nil }
      }
      #expect(outputs == [yPointer])
      #expect(outputs.compactMap { buffers.read($0) }.reduce(Data(), +) == yBytes)
      let endings = events.value.compactMap { event -> ExecFinished? in
        if case let .exit(end) = event { end } else { nil }
      }
      #expect(endings.count == 1)
      #expect(endings.first?.id == y.id)
      #expect(endings.first?.status == .exited(code: 7))
      #expect(endings.first?.error == nil)
      #expect(oldCloses.value == 1)
      #expect(oldEvents.value.allSatisfy { if case .accepted = $0 { true } else { false } })
      oldStream.close(); newStream.close(); oldBox.close(); newBox.close()
      try await old.close()
      try await new.close()
    }
  }
}
