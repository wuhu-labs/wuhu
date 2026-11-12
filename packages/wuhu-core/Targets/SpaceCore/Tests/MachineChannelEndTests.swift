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

@Suite(.deterministicDependencies) struct MachineChannelEndTests {
  @Test(arguments: [false, true], [false, true])
  func endZeroAndFinalOneConflictRegardlessOfArrivalOrder(file: Bool, verdictFirst: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let end = f.snapshot(from: 0, through: 0, ended: true)
    let verdict = f.snapshot(final: 1)
    try await f.answer(verdictFirst ? .control : .output(f.channel), snapshot: verdictFirst ? verdict : end)
    #expect(f.resultCount == 0)
    try await f.answer(verdictFirst ? .output(f.channel) : .control, snapshot: verdictFirst ? end : verdict)
    try await expectInvalidOnce(f)
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == 0 && row.offsets[f.channel] == 0)
      #expect(row.terminalAcks.isEmpty)
      #expect(row.endedChannels.contains(f.channel) == !verdictFirst)
      if !verdictFirst {
        #expect(row.snapshot?.verdict == nil)
        #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == 0)
      }
    } else {
      let row = try #require(f.execRow)
      #expect(row.stdout == 0 && row.cursor == 0 && row.terminalAcks.isEmpty)
      #expect(row.endedChannels.contains(f.channel) == !verdictFirst)
      if !verdictFirst {
        #expect(row.snapshot?.verdict == nil)
        #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == 0)
      }
    }
    #expect(f.outputCount == 0)
    try await f.answer(verdictFirst ? .output(f.channel) : .control, snapshot: verdictFirst ? end : verdict)
    #expect(f.resultCount == 1)
    try await f.cleanupFailure()
    try await f.close()
  }

  @Test(arguments: [false, true], [false, true])
  func exactEndAndFinalOneCompleteOnceInEitherOrder(file: Bool, verdictFirst: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let bytes = Data([0x41])
    let pointer = try #require(f.space.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    let end = f.snapshot(from: 0, through: 1, ended: true)
    let verdict = f.snapshot(final: 1)
    if verdictFirst {
      try await f.answer(.control, snapshot: verdict)
      #expect(f.resultCount == 0 && f.outputCount == 0)
      try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes)
    } else {
      try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes)
      #expect(f.resultCount == 0 && f.outputCount == 1)
      try await f.answer(.control, snapshot: verdict)
    }
    if !file { try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 1, through: 1, ended: true)) }
    #expect(f.outputCount == 1)
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == 1 && row.offsets[f.channel] == 0)
      #expect(row.endedChannels.contains(f.channel) && row.failure == nil)
      #expect(f.resultCount == 0 && f.terminals.isEmpty)
      f.filePeer?.send(.want(channel: f.channel, offset: 1))
      await f.space.drain()
      guard case .success = try #require(f.fileResults.first) else { Issue.record("Expected consumed file success"); return }
      #expect(f.fileRow?.offsets[f.channel] == 1)
      #expect(f.terminals.count == 1)
    } else {
      let row = try #require(f.execRow)
      #expect(row.stdout == 1 && row.cursor == 1 && row.endedChannels.contains(f.channel))
      #expect(row.diagnostic == nil)
      let result = try #require(f.execResults.first)
      #expect(result.error == nil && result.status == .exited(code: 0))
      #expect(result.cursor == 1 && result.tail == bytes)
      #expect(f.terminals.count == 2)
      // The completed stream is closed; the consumer still owns its retained output pointer.
      f.space.machineBuffers.release(pointer)
    }
    #expect(f.resultCount == 1)
    for terminal in f.terminals {
      try await f.acknowledge(terminal, final: 1)
      #expect(f.resultCount == 1)
      #expect(f.fileRow?.failure == nil && f.execRow?.diagnostic == nil)
    }
    #expect(f.resultCount == 1)
    if file {
      #expect(f.fileRow == nil)
      guard case let .success(result) = try #require(f.fileResults.first) else { Issue.record("Terminal ACK changed the file result"); return }
      #expect(result == [:])
    } else {
      let row = try #require(f.execRow)
      #expect(row.terminal && row.diagnostic == nil && row.terminalAcks == ["stdout", "stderr"])
      let result = try #require(f.execResults.first)
      #expect(result.error == nil && result.status == .exited(code: 0))
      #expect(result.cursor == 1 && result.tail == bytes)
    }
    #expect(f.boxFrames.values.withLock { $0.allSatisfy { $0.tag != .operation(f.operation, .stop) } })
    #expect(f.space.machineBuffers.retained(f.operation, channel: f.channel) == 0)
    try await f.close()
  }

  @Test(arguments: [false, true], [false, true])
  func aStaleLowerEndIsInvalidButANonEndingReplayIsIgnored(file: Bool, ended: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let bytes = Data([1, 2])
    let pointer = try #require(f.space.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: 2), pointer: pointer, tail: bytes)
    #expect(f.resultCount == 0 && f.outputCount == 1)
    if !file {
      #expect(f.execRow?.stdout == 2 && f.execRow?.cursor == 2)
      f.execPeer?.send(.consumed(2))
      await f.space.drain()
    }
    let stale = f.snapshot(from: ended ? 1 : 0, through: 1, ended: ended)
    try await f.answer(.output(f.channel), snapshot: stale)
    if ended { try await expectInvalidOnce(f) }
    else {
      #expect(f.resultCount == 0 && f.terminals.isEmpty)
      if file { #expect(f.fileRow?.failure == nil) }
      else { #expect(f.execRow?.diagnostic == nil) }
    }
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == 2 && row.offsets[f.channel] == 0)
      #expect(row.endedChannels.isEmpty && row.snapshot?.verdict == nil)
    } else {
      let row = try #require(f.execRow)
      #expect(row.stdout == 2 && row.cursor == 2)
      #expect(row.endedChannels.isEmpty && row.snapshot?.verdict == nil)
    }
    #expect(f.outputCount == 1)
    try await f.answer(.output(f.channel), snapshot: stale)
    #expect(f.resultCount == (ended ? 1 : 0))
    if ended { try await f.cleanupFailure() }
    try await f.close()
  }

  @Test(arguments: [false, true])
  func aFinalBehindPreviouslyAdmittedOutputIsInvalidEvenWithoutAnEnd(file: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let bytes = Data([1, 2])
    let pointer = try #require(f.space.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: 2), pointer: pointer, tail: bytes)
    #expect(f.resultCount == 0 && f.outputCount == 1)
    if !file {
      f.execPeer?.send(.consumed(2))
      await f.space.drain()
    }
    let verdict = f.snapshot(final: 1)
    try await f.answer(.control, snapshot: verdict)
    try await expectInvalidOnce(f)
    if file { #expect(f.fileRow?.received[f.channel] == 2 && f.fileRow?.offsets[f.channel] == 0) }
    else { #expect(f.execRow?.stdout == 2 && f.execRow?.cursor == 2) }
    #expect(f.outputCount == 1)
    try await f.answer(.control, snapshot: verdict)
    #expect(f.resultCount == 1)
    try await f.cleanupFailure()
    try await f.close()
  }

  @Test(arguments: [false, true], [UInt64(1), 2, 3])
  func overlappingOutputCannotCrossAKnownFinalEvenWhenItDoesNotAdvance(file: Bool, through: UInt64) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let first = Data([1])
    let pointer = try #require(f.space.machineBuffers.put(first, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: 1), pointer: pointer, tail: first)
    try await f.answer(.control, snapshot: f.snapshot(final: 2))
    #expect(f.resultCount == 0 && f.outputCount == 1)
    if !file {
      f.execPeer?.send(.consumed(1))
      await f.space.drain()
    }
    let replay = Data([1, 2, 3].prefix(Int(through)))
    let overlap = try #require(f.space.machineBuffers.put(replay, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: through), pointer: overlap, tail: replay)
    if !file { f.space.machineBuffers.release(overlap) }
    if through > 2 {
      try await expectInvalidOnce(f)
    } else {
      #expect(f.resultCount == 0 && f.terminals.isEmpty)
      if file { #expect(f.fileRow?.failure == nil) }
      else { #expect(f.execRow?.diagnostic == nil) }
    }
    if file { #expect(f.fileRow?.received[f.channel] == 1 && f.fileRow?.offsets[f.channel] == 0) }
    else { #expect(f.execRow?.stdout == 1 && f.execRow?.cursor == 1) }
    #expect(f.outputCount == 1)
    if through > 2 { try await f.cleanupFailure() }
    try await f.close()
  }

  @Test(arguments: [false, true])
  func aGrowingOverlapEndAndVerdictLeaveTheMissingSuffixForItsOwnPoll(file: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let first = Data([1])
    let pointer = try #require(f.space.machineBuffers.put(first, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: 1), pointer: pointer, tail: first)
    #expect(f.outputCount == 1 && f.resultCount == 0)
    if file {
      let emitted = try #require(f.fileFrames.values.withLock { $0.compactMap { if case let .output(pointer) = $0 { pointer } else { nil } }.first })
      #expect(emitted.from == 0 && emitted.through == 1)
      #expect(f.space.machineBuffers.payload(emitted)?.data == first)
      f.filePeer?.send(.want(channel: f.channel, offset: 1))
    } else { f.execPeer?.send(.consumed(1)) }
    await f.space.drain()
    func suffixPollCount() -> Int {
      f.boxFrames.values.withLock { $0.filter { frame in
        guard frame.tag == .operation(f.operation, .output(f.channel)),
              case let .poll(operation, channel, after, _, terminal, _) = frame.exchange else { return false }
        return operation == f.operation && channel == f.channel && after == 1 && terminal == nil
      }.count }
    }
    let pollsBeforeOverlap = suffixPollCount()
    #expect(pollsBeforeOverlap == 1)
    let both = Data([1, 2])
    let overlap = try #require(f.space.machineBuffers.put(both, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(final: 2, from: 0, through: 2, ended: true), pointer: overlap, tail: both)
    #expect(f.outputCount == 1 && f.resultCount == 0 && f.terminals.isEmpty)
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == 1 && row.offsets[f.channel] == 1)
      #expect(row.endedChannels.isEmpty && row.failure == nil)
      #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == 2 && row.snapshot?.verdict != nil)
    } else {
      let row = try #require(f.execRow)
      #expect(row.stdout == 1 && row.cursor == 1 && row.endedChannels.isEmpty)
      #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == 2 && row.snapshot?.verdict != nil)
      #expect(row.diagnostic == nil)
      f.space.machineBuffers.release(overlap)
    }
    #expect(suffixPollCount() - pollsBeforeOverlap == (file ? 0 : 1))
    let suffix = Data([2])
    let last = try #require(f.space.machineBuffers.put(suffix, operation: f.operation, channel: f.channel, from: 1))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 1, through: 2, ended: true), pointer: last, tail: suffix)
    #expect(f.outputCount == 2)
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == 2 && row.offsets[f.channel] == 1 && row.failure == nil)
      #expect(f.resultCount == 0)
      let emitted = try #require(f.fileFrames.values.withLock { $0.compactMap { if case let .output(pointer) = $0 { pointer } else { nil } }.last })
      #expect(emitted.from == 1 && emitted.through == 2)
      #expect(f.space.machineBuffers.payload(emitted)?.data == suffix)
      f.filePeer?.send(.want(channel: f.channel, offset: 2))
      await f.space.drain()
      guard case .success = try #require(f.fileResults.first) else { Issue.record("Expected both file bytes consumed"); return }
      #expect(f.fileRow?.offsets[f.channel] == 2)
    } else {
      let result = try #require(f.execResults.first)
      #expect(result.error == nil && result.status == .exited(code: 0))
      #expect(result.cursor == 2 && result.tail == both)
      #expect(f.execRow?.stdout == 2 && f.execRow?.diagnostic == nil)
      f.space.machineBuffers.release(last)
    }
    #expect(f.resultCount == 1)
    #expect(f.terminals.count == (file ? 1 : 2))
    for terminal in f.terminals {
      try await f.acknowledge(terminal, final: 2)
      #expect(f.resultCount == 1)
      #expect(f.fileRow?.failure == nil && f.execRow?.diagnostic == nil)
    }
    #expect(f.resultCount == 1)
    if file { #expect(f.fileRow == nil) }
    else { #expect(f.execRow?.terminal == true && f.execRow?.terminalAcks == ["stdout", "stderr"]) }
    #expect(f.space.machineBuffers.retained(f.operation, channel: f.channel) == 0)
    try await f.close()
  }

  @Test(arguments: [false, true], [false, true])
  func anAdvancingEndAndADifferentFinalConflictRegardlessOfArrivalOrder(file: Bool, verdictFirst: Bool) async throws {
    let f = try await ChannelEndFixture.attach(file: file)
    let bytes = Data([1])
    let pointer = try #require(f.space.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    let end = f.snapshot(from: 0, through: 1, ended: true)
    let verdict = f.snapshot(final: 2)
    if verdictFirst { try await f.answer(.control, snapshot: verdict) }
    else { try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes) }
    #expect(f.resultCount == 0)
    if file {
      #expect(f.fileRow?.snapshot?.finalOffsets[f.channel]?.rawValue == (verdictFirst ? 2 : 1))
      #expect(f.fileRow?.endedChannels.contains(f.channel) == !verdictFirst)
    } else {
      #expect(f.execRow?.snapshot?.finalOffsets[f.channel]?.rawValue == (verdictFirst ? 2 : 1))
      #expect(f.execRow?.endedChannels.isEmpty == true)
    }
    if verdictFirst { try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes) }
    else { try await f.answer(.control, snapshot: verdict) }
    try await expectInvalidOnce(f)
    let accepted = UInt64(verdictFirst ? 0 : 1)
    if file {
      let row = try #require(f.fileRow)
      #expect(row.received[f.channel] == accepted && row.offsets[f.channel] == 0)
      #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == (verdictFirst ? 2 : 1))
      #expect((row.snapshot?.verdict != nil) == verdictFirst)
    } else {
      let row = try #require(f.execRow)
      #expect(row.stdout == accepted && row.cursor == Int(accepted) && row.endedChannels.isEmpty)
      #expect(row.snapshot?.finalOffsets[f.channel]?.rawValue == (verdictFirst ? 2 : 1))
      #expect((row.snapshot?.verdict != nil) == verdictFirst)
      f.space.machineBuffers.release(pointer)
    }
    #expect(f.outputCount == (verdictFirst ? 0 : 1))
    try await f.answer(.control, snapshot: verdict)
    #expect(f.resultCount == 1)
    try await f.cleanupFailure()
    try await f.close()
  }

  @Test func aDuplicateAdvancingExecEndDoesNotStandInForTheEmptyFrontierAck() async throws {
    let f = try await ChannelEndFixture.attach(file: false)
    let bytes = Data([1])
    let pointer = try #require(f.space.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    let end = f.snapshot(from: 0, through: 1, ended: true)
    try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes)
    #expect(f.execRow?.stdout == 1 && f.execRow?.endedChannels.isEmpty == true)
    try await f.answer(.output(f.channel), snapshot: end, pointer: pointer, tail: bytes)
    #expect(f.execRow?.stdout == 1 && f.execRow?.endedChannels.isEmpty == true)
    #expect(f.resultCount == 0 && f.outputCount == 1)
    #expect(f.execRow?.snapshot?.verdict == nil)
    #expect(f.execRow?.diagnostic == nil)
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 1, through: 1, ended: true))
    #expect(f.execRow?.endedChannels.contains(f.channel) == true)
    #expect(f.resultCount == 0 && f.outputCount == 1 && f.terminals.isEmpty)
    f.execPeer?.send(.consumed(1))
    await f.space.drain()
    #expect(f.space.machineBuffers.retained(f.operation, channel: f.channel) == 0)
    try await f.close()
  }

  @Test(arguments: [false, true])
  func anAdvancingExecEndStillGetsItsAckPollAfterBoxReconnectOrWorkerRoll(roll: Bool) async throws {
    let folder = try ScratchFolder("channel-end-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try await MachineCellTestSpace.open(file: file)
    let f = try await ChannelEndFixture.attach(file: false, storage: old)
    let bytes = Data([1])
    let pointer = try #require(old.machineBuffers.put(bytes, operation: f.operation, channel: f.channel, from: 0))
    try await f.answer(.output(f.channel), snapshot: f.snapshot(from: 0, through: 1, ended: true), pointer: pointer, tail: bytes)
    #expect(f.execRow?.stdout == 1 && f.execRow?.endedChannels.isEmpty == true)
    #expect(f.execRow?.snapshot?.verdict == nil && f.resultCount == 0)
    #expect(f.execRow?.snapshot?.finalOffsets[f.channel]?.rawValue == 1)
    f.execPeer?.send(.consumed(1))
    await old.drain()
    let replacement: MachineCellTestSpace
    if roll {
      replacement = try await MachineCellTestSpace.open(file: file)
      await old.stopWorker()
    } else {
      f.box.close()
      await old.drain()
      replacement = old
    }
    let frames = ChannelEndLog<BoxSocket.Outgoing>()
    let box = try await ChannelEndFixture.connect(replacement, machine: f.machine, frames: frames)
    let polls = frames.values.withLock { $0.compactMap { frame -> UInt64? in
      guard frame.tag == .operation(f.operation, .output(f.channel)),
            case let .poll(operation, channel, after, _, terminal, _) = frame.exchange,
            operation == f.operation, channel == f.channel, terminal == nil else { return nil }
      return after
    } }
    #expect(polls == [1])
    let before = try #require(replacement.worker.cell(MachineCell.ID(f.machine)).operation(f.request.id))
    #expect(before.stdout == 1 && before.endedChannels.isEmpty && before.snapshot?.verdict == nil)
    #expect(before.snapshot?.finalOffsets[f.channel]?.rawValue == 1)
    #expect(before.diagnostic == nil && !before.delivered)
    try await replacement.worker.call(MachineCell.ID(f.machine)) { cell in
      try cell.answer(.init(tag: .operation(f.operation, .output(f.channel)), answer: .snapshot(.init(snapshot: f.snapshot(from: 1, through: 1, ended: true)))), from: cell.box!)
    }
    await replacement.drain()
    let acked = try #require(replacement.worker.cell(MachineCell.ID(f.machine)).operation(f.request.id))
    #expect(acked.stdout == 1 && acked.endedChannels.contains(f.channel))
    #expect(acked.snapshot?.verdict == nil && acked.diagnostic == nil && !acked.delivered)
    #expect(frames.values.withLock { $0.allSatisfy { $0.tag != .operation(f.operation, .start) } })
    box.close()
    await replacement.drain()
    if roll { try await replacement.close() }
    try await f.close()
  }

  private func expectInvalidOnce(_ f: ChannelEndFixture) async throws {
    await f.space.drain()
    #expect(f.resultCount == 1)
    if f.file {
      guard case let .failure(.operation(error)) = try #require(f.fileResults.first) else { Issue.record("Expected file invalidResponse"); return }
      #expect(error.code == .invalidResponse)
      let row = try #require(f.fileRow)
      #expect(row.delivered && row.failure != nil)
      #expect(f.boxFrames.values.withLock { $0.filter { $0.tag == .operation(f.operation, .stop) }.count } == 1)
    } else {
      #expect(try #require(f.execResults.first).error?.code == .invalidResponse)
      let row = try #require(f.execRow)
      #expect(row.terminal && row.delivered && row.diagnostic?.code == .invalidResponse)
    }
    #expect(f.terminals.isEmpty)
    #expect(f.boxFrames.values.withLock { $0.filter { $0.tag == .operation(f.operation, .start) }.count } == 1)
  }
}

private struct ChannelEndFixture: Sendable {
  let space: MachineCellTestSpace
  let machine: String
  let file: Bool
  let operation: UUID
  let token: UUID
  let request: MachineExec
  let box: Peer<BoxSocket>
  let execPeer: Peer<ExecStream>?
  let filePeer: Peer<FileBulk>?
  let boxFrames: ChannelEndLog<BoxSocket.Outgoing>
  let execFrames: ChannelEndLog<ExecStream.Outgoing>
  let fileFrames: ChannelEndLog<FileBulk.Outgoing>

  static func attach(file: Bool, storage: MachineCellTestSpace? = nil) async throws -> Self {
    let space: MachineCellTestSpace
    if let storage { space = storage }
    else { space = try await MachineCellTestSpace.inMemory() }
    let machine = try await space.addMachineV2(name: "channel-end").machine.id.rawValue
    let boxFrames = ChannelEndLog<BoxSocket.Outgoing>()
    let box = try await connect(space, machine: machine, frames: boxFrames)
    let request = MachineExec(id: UUID().uuidString.lowercased(), operation: UUID(), createdAt: fixedDate, group: .shared, argv: ["true"])
    let execFrames = ChannelEndLog<ExecStream.Outgoing>(), fileFrames = ChannelEndLog<FileBulk.Outgoing>()
    let execPeer: Peer<ExecStream>?
    let filePeer: Peer<FileBulk>?
    if file {
      execPeer = nil
      let peer: Peer<FileBulk> = try #require(space.worker.attach(FileBulk.self, to: MachineCell.ID(machine), opening: .init(request: MachineFile(operation: request.operation, start: .init(kind: "read.v1", input: ["path": "/file"])))) {
        if case let .frame(frame) = $0 { fileFrames.values.withLock { $0.append(frame) } }
      })
      filePeer = peer
    } else {
      filePeer = nil
      _ = try await space.worker.call(MachineCell.ID(machine)) { try $0.reserve(request) }
      let peer: Peer<ExecStream> = try #require(space.worker.attach(ExecStream.self, to: MachineCell.ID(machine), opening: .init(exec: request, nonce: UUID())) {
        if case let .frame(frame) = $0 { execFrames.values.withLock { $0.append(frame) } }
      })
      execPeer = peer
    }
    await space.drain()
    let result = Self(space: space, machine: machine, file: file, operation: request.operation, token: UUID(), request: request, box: box, execPeer: execPeer, filePeer: filePeer, boxFrames: boxFrames, execFrames: execFrames, fileFrames: fileFrames)
    try await result.answer(.start, snapshot: result.snapshot())
    return result
  }

  static func connect(_ space: MachineCellTestSpace, machine: String, frames: ChannelEndLog<BoxSocket.Outgoing>) async throws -> Peer<BoxSocket> {
    let pubkey = try await space.space.addMachineTestKey(machine)
    let box: Peer<BoxSocket> = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { frames.values.withLock { $0.append(frame) } }
    })
    await space.drain()
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, ComputerKindSchemas.read]))), from: cell.box!)
    }
    await space.drain()
    return box
  }

  var channel: String { file ? "data" : "stdout" }
  var execRow: MachineOperation? { space.worker.cell(MachineCell.ID(machine)).operation(request.id) }
  var fileRow: MachineFileOperation? { space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) }
  var execResults: [ExecFinished] { execFrames.values.withLock { $0.compactMap { if case let .exit(end) = $0 { end } else { nil } } } }
  var fileResults: [Result<JSONValue, MachineFileFailure>] { fileFrames.values.withLock { $0.compactMap { if case let .finished(result) = $0 { result } else { nil } } } }
  var resultCount: Int { file ? fileResults.count : execResults.count }
  var outputCount: Int {
    if file { fileFrames.values.withLock { $0.filter { if case .output = $0 { true } else { false } }.count } }
    else { execFrames.values.withLock { $0.filter { if case .output = $0 { true } else { false } }.count } }
  }

  var terminals: [BoxPurpose] {
    boxFrames.values.withLock { $0.compactMap { frame in
      guard case let .operation(id, purpose) = frame.tag, id == operation, case .terminal = purpose else { return nil }
      return purpose
    } }
  }

  func snapshot(final: UInt64? = nil, from: UInt64? = nil, through: UInt64? = nil, ended: Bool = false, consumed: Bool = false, outputChannel: String? = nil) -> OperationSnapshot {
    var finals: [String: Offset] = [:]
    if let final {
      finals[channel] = .init(rawValue: final)
      if !file { finals["stderr"] = .init(rawValue: 0) }
    }
    let result: JSONValue = file ? [:] : ["termination": ["tag": "exit", "code": 0]]
    return OperationSnapshot(operation: operation, verdict: final.map { _ in .init(.completed, result: result) }, terminalToken: final.map { _ in token }, finalOffsets: finals, outputConsumed: consumed, channel: from.map { _ in outputChannel ?? channel }, from: from.map { .init(rawValue: $0) }, through: through.map { .init(rawValue: $0) }, channelEnd: ended)
  }

  func answer(_ purpose: BoxPurpose, snapshot: OperationSnapshot, pointer: MachinePointer? = nil, tail: Data = Data()) async throws {
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(.init(tag: .operation(operation, purpose), answer: .snapshot(.init(snapshot: snapshot, output: pointer, tail: tail))), from: cell.box!)
    }
    await space.drain()
  }

  func acknowledge(_ purpose: BoxPurpose, final: UInt64) async throws {
    guard case let .terminal(channel) = purpose else { preconditionFailure("Expected terminal poll") }
    let offset = channel == self.channel ? final : 0
    try await answer(purpose, snapshot: snapshot(final: final, from: offset, through: offset, ended: true, consumed: true, outputChannel: channel))
  }

  func cleanupFailure() async throws {
    if file {
      #expect(space.machineBuffers.retained(operation, channel: channel) == 0)
      try await answer(.stop, snapshot: snapshot())
      #expect(fileRow == nil)
    } else {
      #expect(space.machineBuffers.retained(operation, channel: channel) == 0)
    }
    #expect(resultCount == 1)
  }

  func close() async throws {
    execPeer?.close(); filePeer?.close(); box.close()
    await space.drain()
    try await space.close()
  }
}

private final class ChannelEndLog<Value: Sendable>: Sendable {
  let values = Mutex<[Value]>([])
}
