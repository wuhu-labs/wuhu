#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import OperationClient
import OperationClientTestSupport
import OperationProtocol
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite struct MachineV2StoreTests {
  @Test func durableContractAndGroupIsolation() async throws {
    let space = try Space.inMemory()
    let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: GroupID(rawValue: "shared"), key: key, problemsGroup: .shared)
    try await verifyOperationStoreContract(store)
    let owner = OperationOwner(scope: "restart", key: "one")
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: ["path": "/secret"]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    #expect(try await store.claim(owner, record: record).dispatch)
    let reopened = try await space.machineV2Store(group: GroupID(rawValue: "shared"), key: key, problemsGroup: .shared)
    #expect(try await reopened.lookup(owner)?.id == record.id)
    #expect(try await reopened.claim(owner, record: record).dispatch == false)
    let other = try await space.machineV2Store(group: GroupID(rawValue: "other"), key: key, problemsGroup: .shared)
    #expect(try await other.lookup(owner) == nil)
    await #expect(throws: OperationError.self) { try await other.read(record.id) }
  }
}

import GRDB
import Scratch
import StructuredQueries
import StructuredQueriesSQLite

extension MachineV2StoreTests {
  @Test func reopenSameDatabasePreservesPayloadAndNoPlaintextOrWrongKeyRecovery() async throws {
    let folder = try ScratchFolder("machine-v2-store")
    let url = folder.url.appending(path: "space.sqlite")
    let key = SymmetricKey(size: .bits256)
    let space = try Space.open(file: url)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: ["path": "/private-secret-marker"]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    _ = try await store.claim(.init(scope: "restart", key: "one"), record: record)
    _ = try await store.transaction(record.id) { $0.output["data"] = [.init(data: Data("private-output-marker".utf8))]; $0.committed["data"] = .init(rawValue: 21) }
    let encrypted = try await space.writer.read { db in try #require(try MachineV2OperationRow.where { $0.id.eq(record.id.uuidString) }.fetchOne(db)).record }
    #expect(!encrypted.contains("private-secret-marker"))
    let reopened = try Space.open(file: url)
    let restored = try await reopened.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    #expect(try await restored.read(record.id).output["data"]?.first?.data == Data("private-output-marker".utf8))
    let wrong = try await reopened.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    await #expect(throws: OperationError.self) { try await wrong.read(record.id) }
  }

  @Test func atomicAdmissionAndOwnerUniqueness() async throws {
    let space = try Space.inMemory(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    let dispatches = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0 ..< 20 { group.addTask { try await store.claim(.init(scope: "race", key: "one"), record: record).dispatch } }
      var count = 0; for try await winner in group { if winner { count += 1 } }; return count
    }
    #expect(dispatches == 1)
    for index in 1 ..< 8 {
      let next = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: record.start, description: record.description)
      _ = try await store.claim(.init(scope: "race", key: String(index)), record: next)
    }
    let ninth = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: record.start, description: record.description)
    await #expect(throws: OperationError.self) { try await store.claim(.init(scope: "race", key: "ninth"), record: ninth) }
    #expect(try await store.lookup(.init(scope: "race", key: "ninth")) == nil)
  }

  @Test func tracesAreOneRowPerRoundTripAndGroupFiltered() async throws {
    let space = try Space.inMemory()
    let own = try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared)
    let other = try await space.machineV2TraceSink(group: .init(rawValue: "other"), problemsGroup: .shared)
    let request = UUID(); let path = "/machine/v2/machines/disk/operations/\(UUID())"
    try own(.init(request: request, correlation: "own", path: path, event: .dispatch, elapsed: .zero))
    try own(.init(request: request, correlation: "own", path: path, event: .head, elapsed: .milliseconds(1), status: 200))
    try own(.init(request: request, correlation: "own", path: path, event: .complete, elapsed: .milliseconds(2)))
    try other(.init(request: UUID(), correlation: "private", path: path, event: .dispatch, elapsed: .zero))
    let rows = try await space.query("SELECT correlation_id, event, elapsed_ms, status FROM machine_v2_trace", as: .init(actor: .anonymous, group: .shared))
    #expect(rows.rows == [[.text("own"), .text("complete"), .integer(2), .integer(200)]])
    #expect(throws: OperationError.self) { try own(.init(request: UUID(), correlation: "unsafe", path: path + "?secret=oops", event: .dispatch, elapsed: .zero)) }
    await #expect(throws: SpaceError.self) { try await space.query("SELECT * FROM machine_v2_operations", as: .init(actor: .anonymous, group: .shared)) }
  }

  @Test func problemFingerprintCountsIncidentsNotRetransmissions() async throws {
    let space = try Space.inMemory(); let correlation = UUID()
    let first = try await space.recordMachineV2Problem(group: .shared, traceGroup: .shared, invariant: 13, code: .invalidOffset, incident: "op-one", correlation: correlation)
    let duplicate = try await space.recordMachineV2Problem(group: .shared, traceGroup: .shared, invariant: 13, code: .invalidOffset, incident: "op-one", correlation: UUID())
    let second = try await space.recordMachineV2Problem(group: .shared, traceGroup: .shared, invariant: 13, code: .invalidOffset, incident: "op-two", correlation: UUID())
    #expect(first == duplicate && second == first)
    let rows = try await space.query("SELECT occurrences, invariant FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .anonymous, group: .shared))
    #expect(rows.rows == [[.integer(2), .integer(13)]])
  }
}

import Dependencies
import SpaceFS
import Synchronization

extension MachineV2StoreTests {
  @Test func retentionPinsIncidentsUntilOperatorResolvesAndDoesNotCountExpectedLoss() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let space = try Space.inMemory(); let sink = try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared)
      let correlation = UUID(); let operation = UUID()
      let path = "/machine/v2/machines/disk/operations/\(operation)"
      let request = UUID()
      try sink(.init(request: request, correlation: correlation.uuidString, path: path, event: .failure, elapsed: .milliseconds(1), error: .invalidOffset))
      try sink(.init(request: UUID(), correlation: correlation.uuidString, path: path, event: .failure, elapsed: .milliseconds(1), error: .invalidOffset))
      try sink(.init(request: UUID(), correlation: "ordinary", path: path, event: .failure, elapsed: .milliseconds(1), error: .requestDeadline))
      let problems = try await space.query("SELECT id, occurrences FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .anonymous, group: .shared))
      #expect(problems.rows.count == 1); #expect(problems.rows[0][1] == .integer(1))
      time.withLock { $0 = $0.addingTimeInterval(8 * 86400) }
      try sink(.init(request: UUID(), correlation: "new", path: path, event: .dispatch, elapsed: .zero))
      let retained = try await space.query("SELECT correlation_id FROM machine_v2_trace", as: .init(actor: .anonymous, group: .shared))
      #expect(retained.rows.count == 3); #expect(!retained.rows.contains([.text("ordinary")]))
      guard case let .integer(id) = problems.rows[0][0] else { Issue.record("missing problem id"); return }
      _ = try await space.commitRows(try SpacePath(validating: "/wuhu/machine-v2-problems.table"), edits: [.update(id: id, ["status": "verified"])], in: .shared, acting: .shared)
      time.withLock { $0 = $0.addingTimeInterval(301) }
      try sink(.init(request: UUID(), correlation: "after-resolution", path: path, event: .dispatch, elapsed: .zero))
      let expired = try await space.query("SELECT correlation_id FROM machine_v2_trace", as: .init(actor: .anonymous, group: .shared))
      #expect(!expired.rows.contains([.text(correlation.uuidString)]))
    }
  }
}

extension MachineV2StoreTests {
  @Test func missingProblemsConfigurationIsTypedAndOneTableHoldsCrossGroupCountsOnly() async throws {
    let space = try Space.inMemory()
    await #expect(throws: OperationError.self) { try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: nil) }
    await #expect(throws: OperationError.self) { try await space.machineV2TraceSink(group: .shared, problemsGroup: nil) }
    let owner = GroupID(rawValue: "private")
    let sink = try await space.machineV2TraceSink(group: owner, problemsGroup: .shared)
    try sink(.init(request: UUID(), correlation: UUID().uuidString, path: "/machine/v2/machines/hidden-machine/operations/\(UUID())", event: .failure, elapsed: .zero, error: .invalidResponse))
    let counts = try await space.query("SELECT * FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .anonymous, group: .shared))
    #expect(counts.rows.count == 1)
    #expect(counts.columns == ["id", "first_seen_at", "last_seen_at", "occurrences", "fingerprint", "invariant", "error_code", "status"])
    #expect(!counts.rows.flatMap { $0 }.contains(.text("hidden-machine")))
    #expect(try await space.query("SELECT * FROM machine_v2_trace", as: .init(actor: .anonymous, group: .shared)).rows.isEmpty)
  }
}

extension MachineV2StoreTests {
  @Test func independentOutputAndPendingInputBudgetsRoundTripTogether() async throws {
    let space = try Space.inMemory(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    let kind = KindDescriptor("duplex.v1", inputSchema: [:], resultSchema: [:], inputChannels: [.init("in", windowBytes: 65536)], outputChannels: [.init("out", windowBytes: 131_072)])
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "duplex.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [kind]))
    _ = try await store.claim(.init(scope: "budgets", key: "one"), record: record)
    let bytes = Data(repeating: 42, count: 65536)
    _ = try await store.transaction(record.id) {
      $0.output["out"] = [.init(data: bytes), .init(data: bytes)]
      $0.pendingInputs["in"] = .init(offset: .zero, payload: .init(data: bytes), end: false)
    }
    let restored = try await store.read(record.id)
    #expect(restored.output["out"]?.map(\.byteCount) == [65536, 65536])
    #expect(restored.pendingInputs["in"]?.payload.data == bytes)
    await #expect(throws: OperationError.self) { try await store.transaction(record.id) { $0.output["out", default: []].append(.init(data: Data([1]))) } }
    await #expect(throws: OperationError.self) { try await store.transaction(record.id) { $0.pendingInputs["other"] = .init(offset: .zero, payload: .init(data: bytes), end: false) } }
  }
}

extension MachineV2StoreTests {
  @Test func admissionCountsLiveOperationsAndPrunesSevenDayTerminalReceipts() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let space = try Space.inMemory(); let key = SymmetricKey(size: .bits256)
      let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read])
      var first: UUID?
      for index in 0 ..< 4100 {
        let id = UUID(); if first == nil { first = id }
        let record = ClientRecord(id: id, correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: [:]), description: description)
        _ = try await store.claim(.init(scope: "lifetime", key: String(index)), record: record)
        _ = try await store.transaction(id) { $0.snapshot = .init(operation: id, verdict: .init(.completed, result: .null), terminalToken: UUID(), finalOffsets: ["data": .init(rawValue: 1)], outputConsumed: false) }
      }
      #expect(try await space.machineV2Recovery(group: .shared, key: key).count == 4100)
      let reservations = try await space.writer.read { db in try MachineV2OperationRow.all.fetchAll(db).reduce(0) { $0 + $1.reservedBytes } }
      #expect(reservations == 0)
      time.withLock { $0 = $0.addingTimeInterval(8 * 86400) }
      let next = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: [:]), description: description)
      _ = try await store.claim(.init(scope: "lifetime", key: "after-retention"), record: next)
      #expect(try await space.machineV2Recovery(group: .shared, key: key).count == 1)
      await #expect(throws: OperationError.self) { try await store.read(first!) }
    }
  }

  @Test func integralDoubleSurvivesEncryptedKeyReuse() async throws {
    let space = try Space.inMemory(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256), problemsGroup: .shared)
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: "disk", start: .init(kind: "read.v1", input: ["value": .number(4_294_967_296)]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    let owner = OperationOwner(scope: "numeric", key: "reuse")
    _ = try await store.claim(owner, record: record)
    #expect(try await store.claim(owner, record: record).dispatch == false)
    _ = try await store.transaction(record.id) { $0.stopReason = "test" }
  }
}

extension MachineV2StoreTests {
  @Test func maintenanceIsThrottledAndResolvedIncidentsEventuallyPrune() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let space = try Space.inMemory(); let sink = try await space.machineV2TraceSink(group: .shared, problemsGroup: .shared)
      let request = UUID(); let path = "/machine/v2/machines/disk/operations/\(UUID())"
      try sink(.init(request: request, correlation: UUID().uuidString, path: path, event: .failure, elapsed: .zero, error: .invalidResponse))
      let initial = try await space.writer.read { db in try MachineV2MaintenanceRow.all.fetchAll(db).map(\.ranAt) }
      time.withLock { $0 = $0.addingTimeInterval(30) }
      for _ in 0 ..< 20 { try sink(.init(request: UUID(), correlation: "normal", path: path, event: .complete, elapsed: .zero)) }
      #expect(try await space.writer.read { db in try MachineV2MaintenanceRow.all.fetchAll(db).map(\.ranAt) } == initial)
      let rows = try await space.query("SELECT id FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .anonymous, group: .shared))
      guard case let .integer(id) = rows.rows[0][0] else { Issue.record("missing problem"); return }
      _ = try await space.commitRows(try SpacePath(validating: "/wuhu/machine-v2-problems.table"), edits: [.update(id: id, ["status": "verified"])], in: .shared, acting: .shared)
      time.withLock { $0 = $0.addingTimeInterval(301) }
      try sink(.init(request: UUID(), correlation: "release", path: path, event: .complete, elapsed: .zero))
      #expect(try await space.writer.read { db in try MachineV2IncidentRow.all.fetchAll(db).allSatisfy { $0.problemID == nil } })
      time.withLock { $0 = $0.addingTimeInterval(8 * 86400) }
      try sink(.init(request: UUID(), correlation: "prune", path: path, event: .complete, elapsed: .zero))
      #expect(try await space.writer.read { db in try MachineV2IncidentRow.all.fetchAll(db).isEmpty })
    }
  }
}
