#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import OperationClient
import func OperationClientTestSupport.verifyOperationStoreContract
import OperationProtocol
import Testing

@Test func memoryStoreContract() async throws { try await verifyOperationStoreContract(MemoryOperationStore()) }
@Test func concurrentClaimsConsumeOneDispatchPermission() async throws {
  let store = MemoryOperationStore()
  let owner = OperationOwner(scope: "script", key: "same")
  let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
  let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "phone", start: .init(kind: "ui.v1", input: .null), description: description)
  let count = try await withThrowingTaskGroup(of: Bool.self) { group in
    for _ in 0 ..< 32 { group.addTask { try await store.claim(owner, record: record).dispatch } }
    var count = 0; for try await won in group { if won { count += 1 } }; return count
  }
  #expect(count == 1)
}
