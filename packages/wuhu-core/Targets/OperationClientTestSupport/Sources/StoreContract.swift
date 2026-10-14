#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationClient.ClientRecord
import struct OperationClient.OperationOwner
import protocol OperationClient.OperationStore
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.WriteRequest

public enum StoreContractFailure: Error, Equatable, Sendable { case violation(String) }

public func verifyOperationStoreContract(_ store: any OperationStore) async throws {
  let owner = OperationOwner(scope: "store-contract", key: UUID().uuidString)
  let descriptor = KindDescriptor("query.v1", inputSchema: [:], resultSchema: [:], inputChannels: [.init("stdin")], outputChannels: [.init("data")])
  let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [descriptor])
  let first = ClientRecord(id: UUID(), correlation: UUID(), machine: "phone", start: .init(kind: descriptor.name, input: .null), description: description)
  guard try await store.lookup(owner) == nil else { throw StoreContractFailure.violation("ownerLookup") }
  let claim = try await store.claim(owner, record: first)
  let again = try await store.claim(owner, record: first)
  guard claim.dispatch && !again.dispatch && again.record.id == first.id,
        try await store.lookup(owner)?.id == first.id else { throw StoreContractFailure.violation("dispatchUniqueness") }
  let mismatch = ClientRecord(id: UUID(), correlation: UUID(), machine: first.machine, start: .init(kind: descriptor.name, input: 1), description: description)
  do { _ = try await store.claim(owner, record: mismatch); throw StoreContractFailure.violation("invocationConflict") }
  catch let error as OperationError { guard error.code == .invocationConflict else { throw error } }
  let bytes = ChannelPayload(data: Data([1, 2, 3]))
  let cursor = Offset(rawValue: 3)
  let pending = WriteRequest(offset: Offset(rawValue: 9), payload: bytes, end: true)
  _ = try await store.transaction(first.id) { value in
    value.output["data"] = [bytes]; value.committed["data"] = cursor
    value.pendingInputs["stdin"] = pending; value.accepted["stdin"] = pending.offset
  }
  let saved = try await store.read(first.id)
  guard saved.output["data"] == [bytes], saved.committed["data"] == cursor else { throw StoreContractFailure.violation("outputPayloadAndCursor") }
  guard saved.pendingInputs["stdin"] == pending, saved.accepted["stdin"] == pending.offset else { throw StoreContractFailure.violation("pendingInputAndCursor") }
  do {
    _ = try await store.transaction(first.id) { value in
      value.output["data"] = []; value.committed["data"] = .zero
      value.pendingInputs["stdin"] = .init(offset: .zero, payload: .init(data: Data([9])), end: false)
      value.accepted["stdin"] = .zero
      throw OperationError(.invalidInput)
    }
    throw StoreContractFailure.violation("rollbackError")
  } catch let error as OperationError { guard error.code == .invalidInput else { throw error } }
  let rolledBack = try await store.read(first.id)
  guard rolledBack.output["data"] == saved.output["data"], rolledBack.committed == saved.committed,
        rolledBack.pendingInputs == saved.pendingInputs, rolledBack.accepted == saved.accepted else { throw StoreContractFailure.violation("payloadAndCursorRollback") }
}
