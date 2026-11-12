import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
@testable import SpaceCore
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineCellEvidenceTests {
  @Test(arguments: [false, true], [BoxPurpose.control, .output("stdout"), .terminal("stdout")])
  func conflictingRepeatedEvidenceFailsOnceWithoutReplacingKnownEvidence(changedVerdict: Bool, purpose: BoxPurpose) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "evidence").machine.id.rawValue
    var box = try await EvidenceBox.attach(space, machine: machine)
    var caller = try await EvidenceExec.attach(space, machine: machine)
    _ = try await box.next(.operation(caller.request.operation, .start))
    let operation = caller.request.operation
    let token = UUID()
    let first = OperationSnapshot(operation: operation, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), terminalToken: token, finalOffsets: ["stdout": .init(rawValue: 2), "stderr": .init(rawValue: 0)], outputConsumed: false)
    try await box.answer(.init(tag: .operation(operation, .start), answer: .snapshot(.init(snapshot: first))))
    let known = try #require(space.worker.cell(MachineCell.ID(machine)).operation(caller.request.id))
    #expect(!known.delivered && known.cursor == 0)
    let pointer = try #require(space.machineBuffers.put(Data([1, 2]), operation: operation, channel: "stdout", from: 0))
    let conflicting = OperationSnapshot(operation: operation, verdict: changedVerdict ? .init(.failed, error: .init(.permissionDenied)) : first.verdict, terminalToken: token, finalOffsets: ["stdout": .init(rawValue: changedVerdict ? 2 : 3)], outputConsumed: true, channel: "stdout", from: .init(rawValue: 0), through: .init(rawValue: 2), channelEnd: true)
    let answer = BoxSocket.Incoming(tag: .operation(operation, purpose), answer: .snapshot(.init(snapshot: conflicting, output: pointer, tail: Data([1, 2]))))
    try await box.answer(answer)
    let end = try await caller.finished()
    #expect(end.error?.code == .invalidResponse)
    #expect(end.tail.isEmpty && end.cursor == 0 && end.status == .exited(code: 0))
    let failed = try #require(space.worker.cell(MachineCell.ID(machine)).operation(caller.request.id))
    #expect(failed.terminal && failed.delivered)
    #expect(failed.diagnostic?.code == .invalidResponse)
    #expect(failed.snapshot?.verdict == first.verdict)
    #expect(failed.snapshot?.finalOffsets == first.finalOffsets)
    #expect(failed.stdout == 0 && failed.stderr == 0 && failed.terminalAcks.isEmpty)
    try await box.answer(answer)
    try await caller.expectClosedWithoutAnotherResult()
    #expect(space.worker.cell(MachineCell.ID(machine)).operation(caller.request.id)?.diagnostic?.code == .invalidResponse)
    box.peer.close()
    try await space.close()
  }

  @Test(arguments: [false, true])
  func duplicateChannelNamesRejectTheDescriptionAndFailOpenOperations(input: Bool) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "evidence").machine.id.rawValue
    var box = try await EvidenceBox.attach(space, machine: machine)
    var caller = try await EvidenceExec.attach(space, machine: machine)
    _ = try await box.next(.operation(caller.request.operation, .start))
    let operation = UUID()
    let fileFrames = AsyncStream<FileBulk.Outgoing>.makeStream()
    let file = try #require(space.worker.attach(FileBulk.self, to: MachineCell.ID(machine), opening: .init(request: MachineFile(operation: operation, start: .init(kind: "read.v1", input: ["path": "/file"])))) {
      switch $0 {
      case let .frame(frame): fileFrames.continuation.yield(frame)
      case .closed: fileFrames.continuation.finish()
      }
    })
    _ = try await box.next(.operation(operation, .start))
    let original = ComputerKindSchemas.read
    let duplicate = KindDescriptor(original.name, inputSchema: original.inputSchema, resultSchema: original.resultSchema, inputChannels: input ? [.init("data"), .init("data")] : original.inputChannels, outputChannels: input ? original.outputChannels : [.init("data"), .init("data")])
    try await box.answer(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, duplicate]))))
    #expect(try await caller.finished().error?.code == .invalidResponse)
    try await caller.expectClosedWithoutAnotherResult()
    var completions = 0
    for await frame in fileFrames.stream {
      if case let .finished(result) = frame {
        completions += 1
        guard case let .failure(.operation(error)) = result else { Issue.record("Expected invalidResponse for the open file operation"); continue }
        #expect(error.code == .invalidResponse)
      }
    }
    #expect(completions == 1)
    #expect(space.worker.cell(MachineCell.ID(machine)).presence.state == "lost")
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    file.close(); box.peer.close()
    try await space.close()
  }

  @Test func inputOutputChannelCollisionRejectsTheDescription() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "collision").machine.id.rawValue
    let box = try await EvidenceBox.attach(space, machine: machine)
    let original = ComputerKindSchemas.stagedWrite
    let collision = KindDescriptor(original.name, inputSchema: original.inputSchema, resultSchema: original.resultSchema, inputChannels: original.inputChannels, outputChannels: [.init("data")])
    try await box.answer(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, collision]))))
    #expect(space.worker.cell(MachineCell.ID(machine)).presence.state == "lost")
    box.peer.close()
    try await space.close()
  }

  @Test func outputArrivingAfterAFileRowIsDeletedDiscardsItsWholeWindow() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "evidence").machine.id.rawValue
    var box = try await EvidenceBox.attach(space, machine: machine)
    let operation = UUID()
    let fileFrames = AsyncStream<FileBulk.Outgoing>.makeStream()
    let file = try #require(space.worker.attach(FileBulk.self, to: MachineCell.ID(machine), opening: .init(request: MachineFile(operation: operation, start: .init(kind: "read.v1", input: ["path": "/file"])))) {
      switch $0 {
      case let .frame(frame): fileFrames.continuation.yield(frame)
      case .closed: fileFrames.continuation.finish()
      }
    })
    _ = try await box.next(.operation(operation, .start))
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      var row = cell.fileOperation(operation)!
      try cell.failFile(&row, .operation(.init(.invalidResponse)), cleanup: false)
    }
    for await _ in fileFrames.stream {}
    await space.drain()
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    let pointer = try #require(space.machineBuffers.put(Data([1, 2]), operation: operation, channel: "data", from: 0))
    _ = try #require(space.machineBuffers.put(Data([3]), operation: operation, channel: "other", from: 0))
    let snapshot = OperationSnapshot(operation: operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: "data", from: .init(rawValue: 0), through: .init(rawValue: 2))
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: snapshot, output: pointer))))
    #expect(space.machineBuffers.payload(pointer) == nil)
    #expect(space.machineBuffers.retained(operation, channel: "other") == 0)
    #expect(space.machineBuffers.operationCount == 0)
    file.close(); box.peer.close()
    try await space.close()
  }
}

private struct EvidenceBox {
  let space: MachineCellTestSpace
  let machine: String
  let peer: Peer<BoxSocket>
  var iterator: AsyncStream<BoxSocket.Outgoing>.Iterator

  static func attach(_ space: MachineCellTestSpace, machine: String) async throws -> Self {
    let pubkey = try await space.space.addMachineTestKey(machine)
    let frames = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let peer = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      switch $0 {
      case let .frame(frame): frames.continuation.yield(frame)
      case .closed: frames.continuation.finish()
      }
    })
    var box = Self(space: space, machine: machine, peer: peer, iterator: frames.stream.makeAsyncIterator())
    _ = try await box.next(.describe)
    try await box.answer(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, ComputerKindSchemas.read]))))
    return box
  }

  mutating func next(_ tag: BoxTag) async throws -> BoxSocket.Outgoing {
    while let frame = await iterator.next() {
      if frame.tag == tag {
        await space.drain()
        return frame
      }
    }
    throw EvidenceFixtureEnded()
  }

  func answer(_ frame: BoxSocket.Incoming) async throws {
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(frame, from: cell.box!)
    }
    await space.drain()
  }
}

private struct EvidenceExec {
  let space: MachineCellTestSpace
  let request: MachineExec
  let peer: Peer<ExecStream>
  var iterator: AsyncStream<ExecStream.Outgoing>.Iterator

  static func attach(_ space: MachineCellTestSpace, machine: String) async throws -> Self {
    let request = MachineExec(id: UUID().uuidString.lowercased(), operation: UUID(), createdAt: fixedDate, group: .shared, argv: ["true"])
    _ = try await space.worker.call(MachineCell.ID(machine)) { try $0.reserve(request) }
    let frames = AsyncStream<ExecStream.Outgoing>.makeStream()
    let peer = try #require(space.worker.attach(ExecStream.self, to: MachineCell.ID(machine), opening: .init(exec: request, nonce: UUID())) {
      switch $0 {
      case let .frame(frame): frames.continuation.yield(frame)
      case .closed: frames.continuation.finish()
      }
    })
    await space.drain()
    return Self(space: space, request: request, peer: peer, iterator: frames.stream.makeAsyncIterator())
  }

  mutating func finished() async throws -> ExecFinished {
    while let frame = await iterator.next() {
      switch frame {
      case .accepted: continue
      case .output: Issue.record("Invalid evidence must not deliver output")
      case let .exit(end):
        await space.drain()
        return end
      }
    }
    throw EvidenceFixtureEnded()
  }

  mutating func expectClosedWithoutAnotherResult() async throws {
    while let _ = await iterator.next() { Issue.record("Exec must finish only once") }
    await space.drain()
  }
}

private struct EvidenceFixtureEnded: Error {}
