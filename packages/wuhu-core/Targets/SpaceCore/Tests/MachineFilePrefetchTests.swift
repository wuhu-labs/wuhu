import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import OperationProtocol
import Scratch
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineFilePrefetchTests {
  @Test func outputFetchesFourMiBAheadAndConsumptionRestoresOnePollOfCredit() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space)
    let chunk = Data(repeating: 0x5A, count: 65536)
    try await fill(f, chunk: chunk)
    let first = try #require(f.outputs.first)
    #expect(first.from == 0 && first.through == 65536)
    #expect(f.outputs.count == 1)
    #expect(f.row?.received["data"] == 4 << 20)
    #expect(f.row?.offsets["data"] == 0)
    #expect(f.row?.offered["data"] == 65536)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 4 << 20)
    #expect(f.box.polls(f.operation, channel: "data").count == 64)
    #expect(f.row?.flights[.output("data")] == nil)

    await f.want("data", offset: first.through)
    let next = try #require(f.outputs.last)
    #expect(next.from == 65536 && next.through == 131_072)
    #expect(f.outputs.count == 2)
    expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: 4 << 20)
    #expect(f.row?.offsets["data"] == 65536)
    #expect(f.box.polls(f.operation, channel: "data").count == 65)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == (4 << 20) - 65536)
    _ = try await f.output(.init(data: chunk), from: 4 << 20)
    #expect(f.row?.received["data"] == (4 << 20) + 65536)
    #expect(f.row?.flights[.output("data")] == nil)
    #expect(f.outputs.count == 2)
    f.close(); try await space.close()
  }

  @Test func finalPrefetchedOutputCannotCompleteOrAcknowledgeTerminalBeforeConsumption() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space)
    let first = try await f.output(.init(data: Data([1, 2])), from: 0)
    expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: 2)
    let second = try await f.output(.init(data: Data([3, 4])), from: 2, completed: true)
    #expect(f.row?.received["data"] == 4)
    #expect(f.row?.offsets["data"] == 0)
    #expect(f.row?.offered["data"] == 2)
    #expect(f.outputs == [first])
    #expect(f.results.isEmpty && f.box.terminals(f.operation).isEmpty)
    await f.want("data", offset: first.through)
    #expect(f.outputs == [first, second])
    #expect(f.results.isEmpty && f.box.terminals(f.operation).isEmpty)
    #expect(f.box.polls(f.operation, channel: "data").count == 2)
    await f.want("data", offset: second.through)
    guard case .success = try #require(f.results.first) else { Issue.record("Expected consumed completion"); return }
    #expect(f.results.count == 1)
    let terminal = try #require(f.box.terminals(f.operation).first)
    guard case let .poll(_, channel, after, _, token, _) = terminal.exchange else { Issue.record("Expected terminal acknowledgement"); return }
    #expect(channel == "data" && after == 4 && token != nil)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 0)
    #expect(f.box.starts(f.operation).count == 1)
    let consumed = OperationSnapshot(operation: f.operation, verdict: .init(.completed, result: [:]), terminalToken: token, finalOffsets: ["data": .init(rawValue: 4)], outputConsumed: true)
    try await f.box.answer(.init(tag: terminal.tag, answer: .snapshot(.init(snapshot: consumed))))
    #expect(f.row == nil && f.results.count == 1)
    f.close(); try await space.close()
  }

  @Test func fullDataChannelDoesNotSpendAnotherChannelsPrefetchCredit() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let original = ComputerKindSchemas.read
    let kind = KindDescriptor(original.name, inputSchema: original.inputSchema, resultSchema: original.resultSchema, outputChannels: [.init("data"), .init("audit")])
    let f = try await PrefetchFixture.attach(space, kind: kind)
    let chunk = Data(repeating: 0x3A, count: 65536)
    try await fill(f, chunk: chunk)
    #expect(f.box.polls(f.operation, channel: "data").count == 64)
    #expect(f.row?.flights[.output("data")] == nil)
    expectPoll(try #require(f.box.polls(f.operation, channel: "audit").last), after: 0)
    _ = try await f.output(.init(data: chunk), channel: "audit", from: 0)
    expectPoll(try #require(f.box.polls(f.operation, channel: "audit").last), after: 65536)
    #expect(f.row?.received["audit"] == 65536 && f.row?.offsets["audit"] == 0)
    #expect(f.row?.received["data"] == 4 << 20 && f.row?.offsets["data"] == 0)
    #expect(space.machineBuffers.retained(f.operation, channel: "audit") == 65536)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 4 << 20)
    #expect(f.box.polls(f.operation, channel: "data").count == 64)
    f.close(); try await space.close()
  }

  @Test func nearFullRecordWindowReservesAWholeNormalPollRatherThanAnEmptyRecordPrefix() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space, kind: ComputerKindSchemas.list)
    let full = ChannelPayload(records: [.string(String(repeating: "é", count: 32767))])
    let half = ChannelPayload(records: [.string(String(repeating: "é", count: 16383))])
    #expect(full.byteCount == 65536 && full.count == 1)
    #expect(half.byteCount == 32768 && half.count == 1)
    for index in 0 ..< 63 {
      expectPoll(try #require(f.box.polls(f.operation, channel: "entries").last), after: UInt64(index))
      _ = try await f.output(full, channel: "entries", from: UInt64(index))
    }
    expectPoll(try #require(f.box.polls(f.operation, channel: "entries").last), after: 63)
    _ = try await f.output(half, channel: "entries", from: 63)
    let retained = 63 * full.byteCount + half.byteCount
    #expect(space.machineBuffers.retained(f.operation, channel: "entries") == retained)
    #expect((4 << 20) - retained == 32768)
    #expect(full.byteCount > (4 << 20) - retained)
    #expect(f.row?.received["entries"] == 64 && f.row?.offsets["entries"] == 0)
    #expect(f.row?.offered["entries"] == 1)
    #expect(f.row?.flights[.output("entries")] == nil)
    #expect(f.box.polls(f.operation, channel: "entries").count == 64)
    await f.want("entries", offset: 1)
    expectPoll(try #require(f.box.polls(f.operation, channel: "entries").last), after: 64)
    #expect(f.row?.offsets["entries"] == 1 && f.row?.received["entries"] == 64)
    #expect(space.machineBuffers.retained(f.operation, channel: "entries") == retained - full.byteCount)
    _ = try await f.output(full, channel: "entries", from: 64)
    #expect(f.row?.received["entries"] == 65)
    #expect(f.row?.flights[.output("entries")] == nil)
    #expect(f.box.polls(f.operation, channel: "entries").count == 65)
    f.close(); try await space.close()
  }

  @Test func byteChannelsAlsoReserveAFullNormalPollWhenOnlyHalfAPollFits() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space)
    let chunk = Data(repeating: 0x42, count: 65536)
    for index in 0 ..< 63 {
      expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: UInt64(index * chunk.count))
      _ = try await f.output(.init(data: chunk), from: UInt64(index * chunk.count))
    }
    _ = try await f.output(.init(data: Data(chunk.prefix(32768))), from: UInt64(63 * chunk.count))
    let received = UInt64(63 * chunk.count + 32768)
    #expect(f.row?.received["data"] == received && f.row?.offsets["data"] == 0)
    #expect(f.row?.flights[.output("data")] == nil)
    #expect(f.box.polls(f.operation, channel: "data").count == 64)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == Int(received))
    await f.want("data", offset: 32768)
    expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: received)
    #expect(f.box.polls(f.operation, channel: "data").count == 65)
    #expect(f.outputs.last?.from == 32768 && f.outputs.last?.through == 65536)
    f.close(); try await space.close()
  }

  @Test func partialReplayClampsALargerOverlappingCachePieceToTheAdmittedRange() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space)
    let first = try await f.output(.init(data: Data([1, 2])), from: 0)
    let delayed = try #require(space.machineBuffers.put(Data([1, 2, 3, 4]), operation: f.operation, channel: "data", from: 0))
    let final = OperationSnapshot(operation: f.operation, verdict: .init(.completed, result: [:]), terminalToken: UUID(), finalOffsets: ["data": .init(rawValue: 4)], outputConsumed: false, channel: "data", from: .init(rawValue: 0), through: .init(rawValue: 4), channelEnd: true)
    try await f.box.answer(.init(tag: .operation(f.operation, .output("data")), answer: .snapshot(.init(snapshot: final, output: delayed))))
    #expect(f.outputs == [first] && f.results.isEmpty)
    #expect(f.row?.received["data"] == 2)
    #expect(f.row?.endedChannels.contains("data") == false)
    await f.want("data", offset: 1)
    let partial = try #require(f.outputs.last)
    #expect(partial.from == 1 && partial.through == 2)
    #expect(space.machineBuffers.payload(partial)?.data == Data([2]))
    #expect(f.row?.offered["data"] == 2 && f.row?.received["data"] == 2)
    await f.want("data", offset: 2)
    #expect(f.outputs.count == 2 && f.results.isEmpty)
    let suffix = try #require(space.machineBuffers.get(f.operation, channel: "data", from: 2))
    let admitted = OperationSnapshot(operation: f.operation, verdict: final.verdict, terminalToken: final.terminalToken, finalOffsets: final.finalOffsets, outputConsumed: false, channel: "data", from: .init(rawValue: 2), through: .init(rawValue: 4), channelEnd: true)
    try await f.box.answer(.init(tag: .operation(f.operation, .output("data")), answer: .snapshot(.init(snapshot: admitted, output: suffix))))
    #expect(f.row?.received["data"] == 4)
    #expect(f.outputs.last == suffix && f.results.isEmpty)
    await f.want("data", offset: 4)
    guard case .success = try #require(f.results.first) else { Issue.record("Expected admitted range completion"); return }
    #expect(f.results.count == 1)
    f.close(); try await space.close()
  }

  @Test func workerRollLosesPrefetchedBytesWithoutRestartingOrAcknowledgingThem() async throws {
    let folder = try ScratchFolder("file-prefetch-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try await MachineCellTestSpace.open(file: file)
    let f = try await PrefetchFixture.attach(old)
    let original = try await f.output(.init(data: Data([1, 2, 3, 4])), from: 0)
    await f.want("data", offset: 2)
    #expect(f.row?.received["data"] == 4 && f.row?.offsets["data"] == 2)
    #expect(f.results.isEmpty)
    await old.stopWorker()
    let new = try await MachineCellTestSpace.open(file: file)
    let replacement = try await PrefetchBox.attach(new, machine: f.machine, kind: ComputerKindSchemas.read)
    let row = try #require(new.worker.cell(MachineCell.ID(f.machine)).fileOperation(f.operation))
    guard case let .rangeLost(offset)? = row.failure else { Issue.record("Expected typed loss of the old worker cache"); return }
    #expect(offset == 2 && row.delivered)
    #expect(row.received["data"] == 4 && row.offsets["data"] == 2)
    #expect(new.machineBuffers.payload(original) == nil)
    #expect(new.machineBuffers.retained(f.operation, channel: "data") == 0)
    #expect(replacement.starts(f.operation).isEmpty)
    #expect(replacement.polls(f.operation, channel: "data").isEmpty)
    #expect(replacement.frames.values.withLock { $0.contains { frame in
      guard frame.tag == .operation(f.operation, .stop), case let .stop(_, reason) = frame.exchange else { return false }
      return reason == "rangeLost"
    } })
    replacement.peer.close()
    try await new.close(); try await old.close()
  }

  @Test func delayedPhysicalCleanupCanRefuseAPollWithoutLosingReceivedProgress() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let f = try await PrefetchFixture.attach(space)
    let chunk = Data(repeating: 0x41, count: 65536)
    try await fill(f, chunk: chunk)
    let gate = AsyncStream<Void>.makeStream(), cleaned = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let buffers = space.machineBuffers
    // Hold the emitted release after committing the consumer cursor, without changing the shared scheduler.
    try await space.worker.call(MachineCell.ID(f.machine)) { cell in
      var row = try #require(cell.fileOperation(f.operation))
      row.offsets["data"] = 65536
      cell.ctx.emit {
        for await _ in gate.stream {}
        buffers.release(f.operation, channel: "data", before: 65536)
        cleaned.continuation.finish()
      }
      try cell.finishFileStep(&row, presence: cell.presence)
    }
    await space.drain()
    expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: 4 << 20)
    #expect(buffers.retained(f.operation, channel: "data") == 4 << 20)
    #expect(buffers.put(chunk, operation: f.operation, channel: "data", from: 4 << 20) == nil)
    try await f.box.answer(.init(tag: .operation(f.operation, .output("data")), answer: .transport(.init(.capacityExceeded))))
    #expect(f.row?.received["data"] == 4 << 20)
    #expect(f.row?.failure == nil && f.results.isEmpty)
    #expect(f.box.starts(f.operation).count == 1)
    gate.continuation.finish()
    for await _ in cleaned.stream {}
    await space.drain()
    try await space.worker.call(MachineCell.ID(f.machine)) { cell in
      var row = try #require(cell.fileOperation(f.operation))
      var retry = try #require(row.flights[.output("data")])
      retry.due = cell.now; retry.waiting = false
      row.flights[.output("data")] = retry
      try cell.finishFileStep(&row, presence: cell.presence)
    }
    await space.drain()
    #expect(f.box.polls(f.operation, channel: "data").count == 66)
    expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: 4 << 20)
    let next = try await f.output(.init(data: chunk), from: 4 << 20)
    #expect(buffers.read(next) == chunk)
    #expect(buffers.retained(f.operation, channel: "data") == 4 << 20)
    #expect(f.row?.received["data"] == (4 << 20) + 65536)
    #expect(f.row?.offsets["data"] == 65536)
    #expect(f.row?.failure == nil && f.results.isEmpty)
    f.close(); try await space.close()
  }

  private func fill(_ f: PrefetchFixture, chunk: Data) async throws {
    for index in 0 ..< 64 {
      expectPoll(try #require(f.box.polls(f.operation, channel: "data").last), after: UInt64(index * chunk.count))
      _ = try await f.output(.init(data: chunk), from: UInt64(index * chunk.count))
    }
  }

  private func expectPoll(_ frame: BoxSocket.Outgoing, after expected: UInt64) {
    guard case let .poll(_, _, after, _, terminal, limit) = frame.exchange else { Issue.record("Expected output poll"); return }
    #expect(after == expected && terminal == nil && limit == 65536)
  }
}

private struct PrefetchFixture: Sendable {
  let space: MachineCellTestSpace
  let machine: String
  let operation: UUID
  let box: PrefetchBox
  let caller: Peer<FileBulk>
  let callerFrames: PrefetchLog<FileBulk.Outgoing>

  static func attach(_ space: MachineCellTestSpace, kind: KindDescriptor = ComputerKindSchemas.read) async throws -> Self {
    let machine = try await space.addMachineV2(name: "prefetch").machine.id.rawValue
    let box = try await PrefetchBox.attach(space, machine: machine, kind: kind)
    let operation = UUID()
    let frames = PrefetchLog<FileBulk.Outgoing>()
    let caller = try #require(space.worker.attach(FileBulk.self, to: MachineCell.ID(machine), opening: .init(request: MachineFile(operation: operation, start: .init(kind: kind.name, input: ["path": "/file"])))) {
      if case let .frame(frame) = $0 { frames.values.withLock { $0.append(frame) } }
    })
    await space.drain()
    #expect(box.starts(operation).count == 1)
    let snapshot = OperationSnapshot(operation: operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)
    try await box.answer(.init(tag: .operation(operation, .start), answer: .snapshot(.init(snapshot: snapshot))))
    return Self(space: space, machine: machine, operation: operation, box: box, caller: caller, callerFrames: frames)
  }

  var row: MachineFileOperation? { space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) }
  var outputs: [MachinePointer] {
    callerFrames.values.withLock { $0.compactMap { if case let .output(pointer) = $0 { pointer } else { nil } } }
  }

  var results: [Result<JSONValue, MachineFileFailure>] {
    callerFrames.values.withLock { $0.compactMap { if case let .finished(result) = $0 { result } else { nil } } }
  }

  func want(_ channel: String, offset: UInt64) async {
    caller.send(.want(channel: channel, offset: offset))
    await space.drain()
  }

  func output(_ payload: ChannelPayload, channel: String = "data", from: UInt64, completed: Bool = false) async throws -> MachinePointer {
    let pointer = try #require(space.machineBuffers.put(payload: payload, operation: operation, channel: channel, from: from))
    let snapshot = OperationSnapshot(operation: operation, verdict: completed ? .init(.completed, result: [:]) : nil, terminalToken: completed ? UUID() : nil, finalOffsets: completed ? [channel: .init(rawValue: pointer.through)] : [:], outputConsumed: false, channel: channel, from: .init(rawValue: from), through: .init(rawValue: pointer.through), channelEnd: completed)
    try await box.answer(.init(tag: .operation(operation, .output(channel)), answer: .snapshot(.init(snapshot: snapshot, output: pointer))))
    return pointer
  }

  func close() { caller.close(); box.peer.close() }
}

private struct PrefetchBox: Sendable {
  let space: MachineCellTestSpace
  let machine: String
  let peer: Peer<BoxSocket>
  let frames: PrefetchLog<BoxSocket.Outgoing>

  static func attach(_ space: MachineCellTestSpace, machine: String, kind: KindDescriptor) async throws -> Self {
    let pubkey = try await space.space.addMachineTestKey(machine)
    let frames = PrefetchLog<BoxSocket.Outgoing>()
    let peer = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { frames.values.withLock { $0.append(frame) } }
    })
    await space.drain()
    #expect(frames.values.withLock { $0.first?.tag == .describe })
    let result = Self(space: space, machine: machine, peer: peer, frames: frames)
    try await result.answer(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [kind]))))
    return result
  }

  func answer(_ frame: BoxSocket.Incoming) async throws {
    try await space.worker.call(MachineCell.ID(machine)) { cell in try cell.answer(frame, from: cell.box!) }
    await space.drain()
  }

  func polls(_ operation: UUID, channel: String) -> [BoxSocket.Outgoing] { tagged(.operation(operation, .output(channel))) }
  func starts(_ operation: UUID) -> [BoxSocket.Outgoing] { tagged(.operation(operation, .start)) }
  func terminals(_ operation: UUID) -> [BoxSocket.Outgoing] {
    frames.values.withLock { $0.filter { frame in
      guard case let .operation(id, .terminal(_)) = frame.tag else { return false }
      return id == operation
    } }
  }

  private func tagged(_ tag: BoxTag) -> [BoxSocket.Outgoing] { frames.values.withLock { $0.filter { $0.tag == tag } } }
}

private final class PrefetchLog<Value: Sendable>: Sendable {
  let values = Mutex<[Value]>([])
}
