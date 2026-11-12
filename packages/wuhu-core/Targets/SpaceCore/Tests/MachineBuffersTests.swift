import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MachineBuffersTests {
  @Test func bytesAndRecordsUseTheirOwnOffsetUnits() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let bytes = Data("abcdef".utf8)
    let data = try #require(buffers.put(bytes, operation: operation, channel: "data", from: 20))
    let records = ChannelPayload(records: [.string("entry"), .object(["name": .string("é\n")])])
    let entries = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 3))
    #expect(data.from == 20 && data.through == 26)
    #expect(entries.from == 3 && entries.through == 5)
    #expect(buffers.read(data) == bytes)
    #expect(buffers.payload(data) == ChannelPayload(data: bytes))
    #expect(buffers.payload(entries) == records)
    #expect(buffers.read(entries) == nil)
    #expect(buffers.retained(operation, channel: "data") == bytes.count)
    #expect(buffers.retained(operation, channel: "entries") == records.byteCount)
    #expect(buffers.put(payload: records, operation: operation, channel: "entries", from: 3) == entries)
    #expect(buffers.retained(operation, channel: "entries") == records.byteCount)
  }

  @Test func wantedOffsetReturnsOnlyTheRetainedSuffixWithoutGrowingTheCache() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let records = ChannelPayload(records: [.string("first"), .string("second"), .string("third")])
    _ = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 10))
    _ = try #require(buffers.put(Data([7, 8]), operation: operation, channel: "data", from: 30))
    let suffix = try #require(buffers.get(operation, channel: "entries", from: 11))
    #expect(suffix.from == 11 && suffix.through == 13)
    #expect(buffers.payload(suffix) == records.slice(1 ..< 3))
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "data", from: 31))) == ChannelPayload(data: Data([8])))
    #expect(buffers.retained(operation, channel: "entries") == records.byteCount)
    #expect(buffers.get(operation, channel: "entries", from: 9) == nil)
    #expect(buffers.get(operation, channel: "entries", from: 13) == nil)
    #expect(buffers.get(operation, channel: "missing", from: 11) == nil)
    #expect(buffers.get(UUID(), channel: "entries", from: 11) == nil)
  }

  @Test func releaseTrimsInChannelUnitsAndOnlyForTheNamedOperationAndChannel() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID(), other = UUID()
    let records = ChannelPayload(records: [.string("first"), .string("second"), .string("third")])
    let original = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 10))
    let data = try #require(buffers.put(Data([1, 2, 3, 4]), operation: operation, channel: "data", from: 20))
    let unrelated = try #require(buffers.put(payload: records, operation: other, channel: "entries", from: 10))
    buffers.release(operation, channel: "entries", before: 11)
    #expect(buffers.payload(original) == nil)
    #expect(buffers.get(operation, channel: "entries", from: 10) == nil)
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "entries", from: 11))) == records.slice(1 ..< 3))
    #expect(buffers.retained(operation, channel: "entries") == records.slice(1 ..< 3).byteCount)
    #expect(buffers.read(data) == Data([1, 2, 3, 4]))
    #expect(buffers.payload(unrelated) == records)
    buffers.release(operation, channel: "data", before: 22)
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "data", from: 22))) == ChannelPayload(data: Data([3, 4])))
    #expect(buffers.retained(operation, channel: "data") == 2)
    buffers.release(operation, channel: "entries", before: 13)
    #expect(buffers.retained(operation, channel: "entries") == 0)
    #expect(buffers.get(operation, channel: "entries", from: 12) == nil)
    buffers.release(operation, channel: "entries", before: 10)
    #expect(buffers.retained(other, channel: "entries") == records.byteCount)
  }

  @Test func overlappingReplaysCannotRestoreAReleasedPrefix() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let records = ChannelPayload(records: [.string("first"), .string("second"), .string("third")])
    let original = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 10))
    buffers.release(operation, channel: "entries", before: 11)
    #expect(buffers.put(payload: records, operation: operation, channel: "entries", from: 10) == original)
    #expect(buffers.payload(original) == nil)
    #expect(buffers.get(operation, channel: "entries", from: 10) == nil)
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "entries", from: 11))) == records.slice(1 ..< 3))
    #expect(buffers.retained(operation, channel: "entries") == records.slice(1 ..< 3).byteCount)
    buffers.release(operation, channel: "entries", before: 13)
    #expect(buffers.put(payload: records, operation: operation, channel: "entries", from: 10) == original)
    #expect(buffers.retained(operation, channel: "entries") == 0)

    let data = Data([1, 2, 3, 4])
    let bytes = try #require(buffers.put(data, operation: operation, channel: "data", from: 0))
    buffers.release(operation, channel: "data", before: 2)
    buffers.release(operation, channel: "data", before: 1)
    #expect(buffers.put(data, operation: operation, channel: "data", from: 0) == bytes)
    #expect(buffers.read(bytes) == nil)
    #expect(buffers.payload(bytes) == nil)
    #expect(buffers.get(operation, channel: "data", from: 1) == nil)
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "data", from: 2))) == ChannelPayload(data: Data([3, 4])))
    #expect(buffers.retained(operation, channel: "data") == 2)
  }

  @Test func channelBudgetCountsEncodedRecordBytesNotRecords() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let limit = 4 << 20
    let record = ChannelPayload(records: [.string(String(repeating: "a", count: limit - 2))])
    #expect(record.byteCount == limit)
    let pointer = try #require(buffers.put(payload: record, operation: operation, channel: "entries", from: 0))
    #expect(pointer.through == 1)
    #expect(buffers.retained(operation, channel: "entries") == limit)
    #expect(buffers.put(payload: ChannelPayload(records: [.null]), operation: operation, channel: "entries", from: 1) == nil)
    let data = Data(repeating: 1, count: limit)
    _ = try #require(buffers.put(data, operation: operation, channel: "data", from: 0))
    #expect(buffers.put(Data([1]), operation: operation, channel: "data", from: UInt64(limit)) == nil)
    _ = try #require(buffers.put(Data([1]), operation: UUID(), channel: "data", from: 0))
    buffers.release(operation, channel: "entries", before: 1)
    _ = try #require(buffers.put(payload: ChannelPayload(records: [.null]), operation: operation, channel: "entries", from: 1))
    #expect(buffers.retained(operation, channel: "entries") == 4)
  }

  @Test func execDeliveryAndReplayKeepTheirCursorSemantics() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let first = try #require(buffers.put(Data([1, 2]), operation: operation, channel: "stdout", from: 0))
    let second = try #require(buffers.put(Data([3, 4]), operation: operation, channel: "stdout", from: 2))
    buffers.delivered(first, cursor: 1)
    buffers.delivered(second, cursor: 2)
    #expect(buffers.retained(operation, channel: "stdout", consumed: 1) == 2)
    #expect(buffers.read(first) == Data([1, 2]))
    buffers.consumed(operation, cursor: 1)
    #expect(buffers.read(first) == nil)
    #expect(buffers.read(second) == Data([3, 4]))
    #expect(buffers.put(Data([1, 2]), operation: operation, channel: "stdout", from: 0) == first)
    #expect(buffers.read(first) == nil)
    let prefix = buffers.prefix(second, count: 1)
    #expect(buffers.read(prefix) == Data([3]))
    buffers.remove(prefix)
    #expect(buffers.read(prefix) == nil)
    #expect(buffers.read(second) == Data([3, 4]))
    buffers.discard(operation)
    #expect(buffers.payload(second) == nil)
    #expect(buffers.retained(operation, channel: "stdout") == 0)
  }

  @Test func execInputRetainsPartialAcceptanceAndQueuedEOF() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let input = try #require(buffers.put(Data([1, 2, 3, 4]), operation: operation, channel: "stdin", from: 0))
    #expect(buffers.pend(input, end: false, accepted: 0, window: 65536))
    #expect(buffers.pend(input, end: false, accepted: 0, window: 65536))
    let end = try #require(buffers.put(Data(), operation: operation, channel: "stdin", from: 4))
    #expect(buffers.pend(end, end: true, accepted: 0, window: 65536))
    let partial = try #require(buffers.input(operation, accepted: 2))
    #expect(partial.0.from == 2 && partial.0.through == 4 && !partial.1)
    #expect(buffers.read(partial.0) == Data([3, 4]))
    buffers.accepted(operation, through: 2, ended: false)
    #expect(buffers.input(operation, accepted: 2)?.0 == partial.0)
    buffers.accepted(operation, through: 4, ended: false)
    #expect(buffers.input(operation, accepted: 4)?.0 == end)
    #expect(buffers.input(operation, accepted: 4)?.1 == true)
    buffers.accepted(operation, through: 4, ended: false)
    #expect(buffers.read(end) == Data())
    buffers.accepted(operation, through: 4, ended: true)
    #expect(buffers.input(operation, accepted: 4) == nil)
    #expect(buffers.retained(operation, channel: "stdin") == 0)
  }

  @Test func genericInputsKeepChannelCursorsAndRecordByteBudgetsSeparate() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let records = ChannelPayload(records: [.string("é"), .string("second")])
    let commit = try #require(buffers.put(payload: records, operation: operation, channel: "commit", from: 0))
    #expect(!buffers.pend(commit, end: true, accepted: 0, window: records.byteCount - 1))
    #expect(buffers.pend(commit, end: true, accepted: 0, window: records.byteCount))
    let data = try #require(buffers.put(Data([1, 2, 3]), operation: operation, channel: "data", from: 0))
    #expect(buffers.pend(data, end: false, accepted: 0, window: 3))
    #expect(buffers.pending(operation)?.0 == commit)
    buffers.accepted(operation, channel: "commit", through: 1, ended: false)
    let suffix = try #require(buffers.pending(operation)?.0)
    #expect(suffix.channel == "commit" && suffix.from == 1 && suffix.through == 2)
    #expect(buffers.payload(suffix) == records.slice(1 ..< 2))
    #expect(buffers.read(data) == Data([1, 2, 3]))
    buffers.accepted(operation, channel: "commit", through: 2, ended: true)
    #expect(buffers.pending(operation)?.0 == data)
    #expect(buffers.retained(operation, channel: "commit") == 0)
    buffers.accepted(operation, channel: "data", through: 3, ended: false)
    #expect(buffers.pending(operation) == nil)
    #expect(buffers.retained(operation, channel: "data") == 0)
  }

  @Test func retainedBudgetAfterConsumerOffsetCountsEncodedRecordSuffixesWithoutMutatingRetains() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let records = ChannelPayload(records: [.string("é"), .string("second")])
    let pointer = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 0))
    #expect(buffers.retained(operation, channel: "entries", from: 1) == records.slice(1 ..< 2).byteCount)
    #expect(buffers.retained(operation, channel: "entries", from: 2) == 0)
    #expect(buffers.payload(pointer) == records)
    #expect(buffers.retained(operation, channel: "entries") == records.byteCount)
  }

  @Test func foreignPointersAndDiscardedRangesHaveNoPayload() throws {
    let buffers = MachineBuffers(worker: "worker"), foreign = MachineBuffers(worker: "foreign")
    let operation = UUID()
    let pointer = try #require(buffers.put(Data([1]), operation: operation, channel: "data", from: 7))
    _ = try #require(foreign.put(Data([2]), operation: operation, channel: "data", from: 7))
    #expect(foreign.read(pointer) == nil)
    #expect(foreign.payload(pointer) == nil)
    buffers.discard(operation)
    #expect(buffers.read(pointer) == nil)
    #expect(buffers.payload(pointer) == nil)
    #expect(buffers.get(operation, channel: "data", from: 7) == nil)
  }

  @Test func aSuppressedAnswerAfterOperationDiscardLeavesNoWindow() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let payload = ChannelPayload(records: [.string("late answer")])
    _ = try #require(buffers.put(payload: payload, operation: operation, channel: "entries", from: 0))
    buffers.discard(operation)
    let late = try #require(buffers.put(payload: payload, operation: operation, channel: "entries", from: 0))
    #expect(buffers.operationCount == 1)
    buffers.release(late)
    #expect(buffers.payload(late) == nil)
    #expect(buffers.retained(operation, channel: "entries") == 0)
    #expect(buffers.operationCount == 0)
  }

  @Test func cancellingAnIdenticalAnswerKeepsTheReplacementReadable() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let payload = ChannelPayload(data: Data([1, 2, 3]))
    let cancelled = try #require(buffers.put(payload: payload, operation: operation, channel: "data", from: 0))
    let replacement = try #require(buffers.put(payload: payload, operation: operation, channel: "data", from: 0))
    #expect(cancelled == replacement)
    #expect(buffers.retained(operation, channel: "data") == payload.byteCount)
    buffers.release(cancelled)
    #expect(buffers.payload(replacement) == payload)
    #expect(buffers.read(replacement) == payload.data)
    #expect(buffers.retained(operation, channel: "data") == payload.byteCount)
    buffers.release(replacement)
    #expect(buffers.payload(replacement) == nil)
    #expect(buffers.operationCount == 0)
  }

  @Test func aSuppressedLiveOperationPieceNoLongerCostsItsChannelBudget() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let limit = 4 << 20
    let live = try #require(buffers.put(Data([9]), operation: operation, channel: "other", from: 0))
    let full = Data(repeating: 1, count: limit)
    let cancelled = try #require(buffers.put(full, operation: operation, channel: "data", from: 0))
    #expect(buffers.put(Data([2]), operation: operation, channel: "data", from: UInt64(limit)) == nil)
    buffers.release(cancelled)
    #expect(buffers.operationCount == 1)
    #expect(buffers.retained(operation, channel: "data") == 0)
    #expect(buffers.read(live) == Data([9]))
    let replacement = try #require(buffers.put(full, operation: operation, channel: "data", from: UInt64(limit)))
    #expect(buffers.read(replacement) == full)
    #expect(buffers.retained(operation, channel: "data") == limit)
  }

  @Test func pointerReleasePreservesConsumerFloorsAndReleasesTrimmedReplayRetains() throws {
    let buffers = MachineBuffers(worker: "worker")
    let operation = UUID()
    let payload = ChannelPayload(records: [.string("first"), .string("second")])
    _ = try #require(buffers.put(payload: payload, operation: operation, channel: "entries", from: 0))
    buffers.release(operation, channel: "entries", before: 1)
    let replay = try #require(buffers.put(payload: payload, operation: operation, channel: "entries", from: 0))
    buffers.release(replay)
    #expect(buffers.payload(try #require(buffers.get(operation, channel: "entries", from: 1))) == payload.slice(1 ..< 2))
    buffers.release(replay)
    #expect(buffers.retained(operation, channel: "entries") == 0)
    #expect(buffers.operationCount == 1)
    _ = try #require(buffers.put(payload: payload, operation: operation, channel: "entries", from: 0))
    #expect(buffers.get(operation, channel: "entries", from: 0) == nil)
    #expect(buffers.retained(operation, channel: "entries") == payload.slice(1 ..< 2).byteCount)

    let exec = UUID()
    let pointer = try #require(buffers.put(Data([1]), operation: exec, channel: "stdout", from: 0))
    _ = try #require(buffers.put(Data([1]), operation: exec, channel: "stdout", from: 0))
    buffers.delivered(pointer, cursor: 1)
    buffers.consumed(exec, cursor: 1)
    buffers.release(pointer)
    #expect(buffers.read(pointer) == nil)
    #expect(buffers.operationCount == 2)
    #expect(buffers.put(Data([1]), operation: exec, channel: "stdout", from: 0) == pointer)
    #expect(buffers.read(pointer) == nil)
  }

  @Test func aNewWorkerCannotReadTheOldWorkersCache() async throws {
    let folder = try ScratchFolder("machine-buffers")
    let file = folder.url.appending(path: "space.sqlite")
    let old = try Space.open(file: file), new = try Space.open(file: file)
    let operation = UUID()
    let oldBuffers = old.machineBuffers, newBuffers = new.machineBuffers
    let pointer = try #require(oldBuffers.put(Data([1, 2]), operation: operation, channel: "data", from: 0))
    #expect(oldBuffers.worker != newBuffers.worker)
    #expect(newBuffers.payload(pointer) == nil)
    #expect(newBuffers.get(operation, channel: "data", from: 0) == nil)
    await old.quiesceWorker()
    #expect(newBuffers.payload(pointer) == nil)
    let fresh = try #require(newBuffers.put(Data([3, 4]), operation: operation, channel: "data", from: 0))
    #expect(newBuffers.read(fresh) == Data([3, 4]))
    #expect(oldBuffers.payload(fresh) == nil)
    try await old.close()
    try await new.close()
  }
}
