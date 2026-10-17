#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationClient.ClientRecord
import struct OperationClient.OperationOwner
import protocol OperationClient.OperationStore
import struct OperationClient.OutputChunk
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteRequest

public enum StoreContractFailure: Error, Equatable, Sendable { case violation(String) }

/// What every `OperationStore` promises its driver: one claim per owner, cursors and pending input round-trip, output is
/// appended one chunk at a time and trimmed by sequence, `live` lists exactly the records with work left, and a record set
/// aside leaves `live` holding nothing.
public func verifyOperationStoreContract(_ store: any OperationStore) async throws {
  let owner = OperationOwner(scope: "store-contract", key: UUID().uuidString)
  let descriptor = KindDescriptor("query.v1", inputSchema: [:], resultSchema: [:], inputChannels: [.init("stdin")], outputChannels: [.init("data")])
  let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [descriptor])
  let first = ClientRecord(id: UUID(), correlation: UUID(), machine: "phone", start: .init(kind: descriptor.name, input: .null), description: description)
  guard try await store.lookup(owner) == nil else { throw StoreContractFailure.violation("ownerLookup") }
  let claim = try await store.claim(owner, record: first)
  let again = try await store.claim(owner, record: first)
  guard claim.dispatch, !again.dispatch, again.record.id == first.id, try await store.lookup(owner)?.id == first.id else { throw StoreContractFailure.violation("dispatchUniqueness") }
  let mismatch = ClientRecord(id: UUID(), correlation: UUID(), machine: first.machine, start: .init(kind: descriptor.name, input: 1), description: description)
  do { _ = try await store.claim(owner, record: mismatch); throw StoreContractFailure.violation("invocationConflict") }
  catch let error as OperationError { guard error.code == .invocationConflict else { throw error } }

  var record = claim.record
  let chunks = (0 ..< 3).map { OutputChunk(sequence: UInt64($0), channel: "data", from: .init(rawValue: UInt64($0)), payload: .init(data: Data([UInt8($0)]))) }
  let pending = WriteRequest(offset: Offset(rawValue: 9), payload: .init(data: Data([1, 2, 3])), end: true)
  for chunk in chunks {
    record.output.append(chunk); record.committed["data"] = chunk.through; record.nextSequence = chunk.sequence + 1
    try await store.save(record, appending: chunk)
  }
  record.pendingInputs["stdin"] = pending; record.accepted["stdin"] = pending.offset
  try await store.save(record, appending: nil)
  var saved = try await store.read(first.id)
  guard saved.output == chunks, saved.committed["data"] == .init(rawValue: 3), saved.nextSequence == 3 else { throw StoreContractFailure.violation("outputAppend") }
  guard saved.pendingInputs["stdin"] == pending, saved.accepted["stdin"] == pending.offset else { throw StoreContractFailure.violation("pendingInputAndCursor") }

  record.output.removeFirst(2); record.consumed["data"] = .init(rawValue: 2); record.pendingInputs = [:]
  try await store.trim(record, removing: [0, 1])
  saved = try await store.read(first.id)
  guard saved.output == [chunks[2]], saved.consumed["data"] == .init(rawValue: 2), saved.pendingInputs.isEmpty else { throw StoreContractFailure.violation("trim") }
  guard try await store.live().map(\.id).contains(first.id) else { throw StoreContractFailure.violation("liveListed") }

  record.snapshot = OperationSnapshot(operation: first.id, verdict: .init(.completed, result: .null), terminalToken: UUID(), finalOffsets: ["data": .init(rawValue: 3)], outputConsumed: true)
  record.output = []; record.terminalAcknowledged = true
  try await store.trim(record, removing: [2])
  saved = try await store.read(first.id)
  guard saved.retired, saved.output.isEmpty else { throw StoreContractFailure.violation("retire") }
  guard try await !store.live().map(\.id).contains(first.id) else { throw StoreContractFailure.violation("retiredNotLive") }

  let other = ClientRecord(id: UUID(), correlation: UUID(), machine: "phone", start: .init(kind: descriptor.name, input: 2), description: description)
  var kept = try await store.claim(OperationOwner(scope: "store-contract", key: UUID().uuidString), record: other).record
  let chunk = OutputChunk(sequence: 0, channel: "data", from: .init(rawValue: 0), payload: .init(data: Data([7])))
  kept.output = [chunk]; kept.committed["data"] = chunk.through; kept.nextSequence = 1
  try await store.save(kept, appending: chunk)
  try await store.setAside(other.id)
  guard try await !store.live().map(\.id).contains(other.id), try await store.read(other.id).output.isEmpty else { throw StoreContractFailure.violation("setAside") }
}
