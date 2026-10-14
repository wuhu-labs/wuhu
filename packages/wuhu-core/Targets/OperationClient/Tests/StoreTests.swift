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

private actor DroppingStore: OperationStore {
  let base = MemoryOperationStore()
  let field: String
  init(field: String) { self.field = field }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func transaction(_ id: UUID, _ update: @Sendable (inout ClientRecord) throws -> Void) async throws -> ClientRecord {
    let field = field
    do {
      return try await base.transaction(id) { value in
        try update(&value)
        if field == "output" { value.output = [:] }
        if field == "pending" { value.pendingInputs = [:] }
      }
    } catch {
      if field.hasPrefix("rollback") {
        _ = try await base.transaction(id) { value in
          if field == "rollbackOutput" { value.output = [:] }
          if field == "rollbackInput" { value.pendingInputs = [:] }
        }
      }
      throw error
    }
  }
}

@Test(arguments: ["output", "pending", "rollbackOutput", "rollbackInput"]) func storeContractRejectsDroppedPayload(field: String) async throws {
  var rejected = false
  do { try await verifyOperationStoreContract(DroppingStore(field: field)) } catch { rejected = true }
  #expect(rejected)
}
