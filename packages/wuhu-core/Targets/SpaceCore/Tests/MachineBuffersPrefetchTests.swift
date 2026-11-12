import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.ChannelPayload
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MachineBuffersPrefetchTests {
  @Test func logicalByteBudgetCountsOnlyTheSuffixWithoutReleasingPhysicalPieces() throws {
    let buffers = MachineBuffers(worker: "prefetch")
    let operation = UUID(), unrelated = UUID()
    let first = try #require(buffers.put(Data([1, 2, 3, 4]), operation: operation, channel: "data", from: 10))
    let second = try #require(buffers.put(Data([5, 6]), operation: operation, channel: "data", from: 14))
    let other = try #require(buffers.put(Data([7, 8, 9]), operation: operation, channel: "other", from: 10))
    let foreign = try #require(buffers.put(Data([0]), operation: unrelated, channel: "data", from: 10))
    for (offset, expected) in [(0, 6), (10, 6), (12, 4), (14, 2), (15, 1), (16, 0), (100, 0)] {
      #expect(buffers.retained(operation, channel: "data", from: UInt64(offset)) == expected)
    }
    #expect(buffers.retained(operation, channel: "missing", from: 0) == 0)
    #expect(buffers.retained(UUID(), channel: "data", from: 0) == 0)
    #expect(buffers.retained(operation, channel: "data") == 6)
    #expect(buffers.read(first) == Data([1, 2, 3, 4]))
    #expect(buffers.read(second) == Data([5, 6]))
    #expect(buffers.read(other) == Data([7, 8, 9]))
    #expect(buffers.read(foreign) == Data([0]))
    #expect(buffers.operationCount == 2)
  }

  @Test func recordOffsetsBudgetEncodedUtf8SuffixesAndDoNotChangeRetainCounts() throws {
    let buffers = MachineBuffers(worker: "prefetch")
    let operation = UUID()
    let records = ChannelPayload(records: [.string("é\n"), .object(["name": .string("世界")]), .string("last")])
    let first = try #require(buffers.put(payload: records, operation: operation, channel: "entries", from: 7))
    #expect(buffers.put(payload: records, operation: operation, channel: "entries", from: 7) == first)
    let last = ChannelPayload(records: [.string("next")])
    let second = try #require(buffers.put(payload: last, operation: operation, channel: "entries", from: 10))
    #expect(records.byteCount > records.count)
    #expect(buffers.retained(operation, channel: "entries", from: 0) == records.byteCount + last.byteCount)
    #expect(buffers.retained(operation, channel: "entries", from: 8) == records.slice(1 ..< 3).byteCount + last.byteCount)
    #expect(buffers.retained(operation, channel: "entries", from: 10) == last.byteCount)
    #expect(buffers.retained(operation, channel: "entries", from: 11) == 0)
    #expect(buffers.payload(first) == records)
    #expect(buffers.payload(second) == last)
    #expect(buffers.retained(operation, channel: "entries") == records.byteCount + last.byteCount)
    buffers.release(first)
    #expect(buffers.payload(first) == records)
    buffers.release(first)
    #expect(buffers.payload(first) == nil)
    #expect(buffers.payload(second) == last)
  }

  @Test func logicalCreditDoesNotBypassTheHardCapWhilePhysicalCleanupIsDelayed() throws {
    let buffers = MachineBuffers(worker: "prefetch")
    let operation = UUID()
    let chunk = Data(repeating: 0x5A, count: 65536)
    for index in 0 ..< 64 {
      _ = try #require(buffers.put(chunk, operation: operation, channel: "data", from: UInt64(index * chunk.count)))
    }
    let end = UInt64(4 << 20)
    #expect(buffers.retained(operation, channel: "data", from: 65536) == (4 << 20) - 65536)
    #expect(buffers.retained(operation, channel: "data") == 4 << 20)
    #expect(buffers.put(chunk, operation: operation, channel: "data", from: end) == nil)
    buffers.release(operation, channel: "data", before: 65536)
    let next = try #require(buffers.put(chunk, operation: operation, channel: "data", from: end))
    #expect(buffers.retained(operation, channel: "data") == 4 << 20)
    buffers.release(operation, channel: "data", before: 7)
    #expect(buffers.get(operation, channel: "data", from: 7) == nil)
    #expect(buffers.read(next) == chunk)
    #expect(buffers.retained(operation, channel: "data", from: 65536) == 4 << 20)
  }
}
