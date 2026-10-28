import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import GRDB
import OperationClient
import OperationClientTestSupport
import OperationProtocol
import OperationRuntime
import struct SpaceContract.GroupID
@testable import SpaceCore
import StructuredQueries
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct MachineV2StoreTests {
  @Test func durableContractAndGroupIsolation() async throws {
    let space = try machineSpace()
    let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: GroupID(rawValue: "shared"), key: key)
    try await verifyOperationStoreContract(store, machine: try await storeMachine("phone", space: space))
    let owner = OperationOwner(scope: "restart", key: "one")
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: ["path": "/secret"]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    #expect(try await store.claim(owner, record: record).dispatch)
    let reopened = try await space.machineV2Store(group: GroupID(rawValue: "shared"), key: key)
    #expect(try await reopened.lookup(owner)?.id == record.id)
    #expect(try await reopened.claim(owner, record: record).dispatch == false)
    let other = try await space.machineV2Store(group: GroupID(rawValue: "other"), key: key)
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
    let store = try await space.machineV2Store(group: .shared, key: key)
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: ["path": "/private-secret-marker"]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    _ = try await store.claim(.init(scope: "restart", key: "one"), record: record)
    var written = record
    let chunk = OutputChunk(sequence: 0, channel: "data", from: .zero, payload: .init(data: Data("private-output-marker".utf8)))
    written.output = [chunk]; written.committed["data"] = chunk.through; written.nextSequence = 1
    try await store.save(written, appending: chunk)
    let encrypted = try await space.writer.read { db in try #require(try MachineV2OperationRow.where { $0.id.eq(record.id.uuidString) }.fetchOne(db)).record }
    #expect(!encrypted.contains("private-secret-marker"))
    let reopened = try Space.open(file: url)
    let restored = try await reopened.machineV2Store(group: .shared, key: key)
    #expect(try await restored.read(record.id).output.first?.payload.data == Data("private-output-marker".utf8))
    let wrong = try await reopened.machineV2Store(group: .shared, key: .init(size: .bits256))
    await #expect(throws: OperationError.self) { try await wrong.read(record.id) }
  }

  @Test func atomicAdmissionAndOwnerUniqueness() async throws {
    let space = try machineSpace(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256))
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    let dispatches = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0 ..< 20 { group.addTask { try await store.claim(.init(scope: "race", key: "one"), record: record).dispatch } }
      var count = 0; for try await winner in group { if winner { count += 1 } }; return count
    }
    #expect(dispatches == 1)
    // Admission counts bytes, never operations: one owner scope claims as many as the machine's buffer holds, and the claim
    // past it is refused by the buffer.
    let fits = record.description.limits.bufferBytes / record.reservation
    for index in 1 ..< fits {
      let next = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: record.start, description: record.description)
      _ = try await store.claim(.init(scope: "race", key: String(index)), record: next)
    }
    let past = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: record.start, description: record.description)
    await #expect { try await store.claim(.init(scope: "race", key: "past"), record: past) } throws: {
      ($0 as? OperationError)?.details?.object?["reason"] == "machineBufferBytes"
    }
    #expect(try await store.lookup(.init(scope: "race", key: "past")) == nil)
  }

  /// Retained output is either this server's chunks or an earlier server's per-channel rows: a chunk that does not open is a
  /// store failure, never output skipped; an earlier server's rows drop the operation's output and go with its next write.
  @Test func damagedOutputFailsAndEarlierOutputIsDropped() async throws {
    let space = try machineSpace()
    let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key)
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read])
    let damaged = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: description)
    _ = try await store.claim(.init(scope: "output", key: "damaged"), record: damaged)
    var written = damaged
    let chunk = OutputChunk(sequence: 0, channel: "data", from: .zero, payload: .init(data: Data("kept".utf8)))
    written.output = [chunk]; written.committed["data"] = chunk.through; written.nextSequence = 1
    try await store.save(written, appending: chunk)
    try await space.writer.write { db in
      try MachineV2OutputRow.where { $0.operationID.eq(damaged.id.uuidString) }.update { $0.payload = "damaged" }.execute(db)
    }
    await #expect { try await store.read(damaged.id) } throws: { ($0 as? OperationError)?.code == .storeUnavailable }

    let earlier = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: description)
    _ = try await store.claim(.init(scope: "output", key: "earlier"), record: earlier)
    try await space.writer.write { db in
      let id = earlier.id.uuidString + "/data/0"
      let row = try MachineV2OutputRow(id: id, operationID: earlier.id.uuidString, channel: "data", sequence: 0, payload: V2Records.seal(ChannelPayload(data: Data("old".utf8)), key: key, context: "shared" + id))
      try MachineV2OutputRow.insert { row }.execute(db)
    }
    let loaded = try await store.read(earlier.id)
    #expect(loaded.discard)
    #expect(loaded.output.isEmpty)
    try await store.save(loaded, appending: nil)
    let left = try await space.writer.read { db in try MachineV2OutputRow.where { $0.operationID.eq(earlier.id.uuidString) }.fetchCount(db) }
    #expect(left == 0)
  }
}

import Dependencies
import SpaceFS
import Synchronization

extension MachineV2StoreTests {
  @Test func independentOutputAndPendingInputBudgetsRoundTripTogether() async throws {
    let space = try machineSpace(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256))
    let kind = KindDescriptor("duplex.v1", inputSchema: [:], resultSchema: [:], inputChannels: [.init("in", windowBytes: 65536)], outputChannels: [.init("out", windowBytes: 131_072)])
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "duplex.v1", input: [:]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [kind]))
    _ = try await store.claim(.init(scope: "budgets", key: "one"), record: record)
    let bytes = Data(repeating: 42, count: 65536)
    var next = record
    func append(_ payload: Data, to record: inout ClientRecord) -> OutputChunk {
      let chunk = OutputChunk(sequence: record.nextSequence, channel: "out", from: record.committed["out"] ?? .zero, payload: .init(data: payload))
      record.output.append(chunk); record.committed["out"] = chunk.through; record.nextSequence += 1
      return chunk
    }
    for _ in 0 ..< 2 { let chunk = append(bytes, to: &next); try await store.save(next, appending: chunk) }
    next.pendingInputs["in"] = .init(offset: .zero, payload: .init(data: bytes), end: false)
    try await store.save(next, appending: nil)
    let restored = try await store.read(record.id)
    #expect(restored.output.map(\.payload.byteCount) == [65536, 65536])
    #expect(restored.pendingInputs["in"]?.payload.data == bytes)
    var over = next
    let excess = append(Data([1]), to: &over)
    await #expect(throws: OperationError.self) { try await store.save(over, appending: excess) }
    var stray = next
    stray.pendingInputs["other"] = .init(offset: .zero, payload: .init(data: bytes), end: false)
    await #expect(throws: OperationError.self) { try await store.save(stray, appending: nil) }
  }
}

extension MachineV2StoreTests {
  @Test func admissionCountsLiveOperationsAndPrunesSevenDayTerminalReceipts() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let space = try machineSpace(); let key = SymmetricKey(size: .bits256)
      let store = try await space.machineV2Store(group: .shared, key: key)
      // The buffer holds one operation's reservation, so each claim is admitted only because the one before it settled.
      var limits = OperationLimits(); limits.bufferBytes = ComputerKindSchemas.read.outputChannels.reduce(0) { $0 + $1.windowBytes }
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [ComputerKindSchemas.read])
      var first: UUID?
      for index in 0 ..< 3 {
        let id = UUID(); if first == nil { first = id }
        let record = ClientRecord(id: id, correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: description)
        _ = try await store.claim(.init(scope: "lifetime", key: String(index)), record: record)
        var terminal = record
        terminal.snapshot = .init(operation: id, verdict: .init(.completed, result: .null), terminalToken: UUID(), finalOffsets: ["data": .init(rawValue: 1)], outputConsumed: true)
        terminal.terminalAcknowledged = true
        try await store.save(terminal, appending: nil)
      }
      #expect(try await store.live().isEmpty)
      let reservations = try await space.writer.read { db in try MachineV2OperationRow.all.fetchAll(db).reduce(0) { $0 + $1.reservedBytes } }
      #expect(reservations == 0)
      time.withLock { $0 = $0.addingTimeInterval(8 * 86400) }
      let next = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: description)
      _ = try await store.claim(.init(scope: "lifetime", key: "after-retention"), record: next)
      #expect(try await store.live().count == 1)
      let past = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: [:]), description: description)
      await #expect { try await store.claim(.init(scope: "lifetime", key: "past"), record: past) } throws: {
        ($0 as? OperationError)?.details?.object?["reason"] == "machineBufferBytes"
      }
      await #expect(throws: OperationError.self) { try await store.read(first!) }
    }
  }

  @Test func integralDoubleSurvivesEncryptedKeyReuse() async throws {
    let space = try machineSpace(); let store = try await space.machineV2Store(group: .shared, key: .init(size: .bits256))
    let record = ClientRecord(id: UUID(), correlation: UUID(), machine: try await storeMachine("disk", space: space), start: .init(kind: "read.v1", input: ["value": .number(4_294_967_296)]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
    let owner = OperationOwner(scope: "numeric", key: "reuse")
    _ = try await store.claim(owner, record: record)
    #expect(try await store.claim(owner, record: record).dispatch == false)
    var stopped = record
    stopped.stopReason = "test"
    try await store.save(stopped, appending: nil)
  }
}

extension MachineV2StoreTests {
  @Test func machineActiveOperationsAreNotCounted() async throws {
    let space = try machineSpace(); let key = SymmetricKey(size: .bits256)
    let first = try await space.machineV2Store(group: .shared, key: key)
    let second = try await space.machineV2Store(group: .init(rawValue: "other"), key: key)
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: OperationLimits(), kinds: [ComputerKindSchemas.read])
    func record() async throws -> ClientRecord { .init(id: UUID(), correlation: UUID(), machine: try await storeMachine("shared_machine", space: space), start: .init(kind: "read.v1", input: [:]), description: description) }
    for n in 0 ..< 40 {
      _ = try await (n.isMultiple(of: 2) ? first : second).claim(.init(scope: "script-\(n)", key: "start"), record: try await record())
    }
  }

  @Test func machineBufferReservationsAreSharedButScriptCapacityRemainsGroupScoped() async throws {
    let space = try machineSpace(); let key = SymmetricKey(size: .bits256)
    let first = try await space.machineV2Store(group: .shared, key: key)
    let second = try await space.machineV2Store(group: .init(rawValue: "other"), key: key)
    var limits = OperationLimits(); limits.bufferBytes = 16 * 1024 * 1024
    let descriptor = KindDescriptor("large.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("out", windowBytes: 8 * 1024 * 1024)])
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [descriptor])
    func record(machine: String = "shared_machine") async throws -> ClientRecord { .init(id: UUID(), correlation: UUID(), machine: try await storeMachine(machine, space: space), start: .init(kind: "large.v1", input: [:]), description: description) }
    _ = try await first.claim(.init(scope: "script", key: "one"), record: try await record())
    _ = try await second.claim(.init(scope: "script", key: "two"), record: try await record())
    do { _ = try await second.claim(.init(scope: "another-script", key: "three"), record: try await record()); Issue.record("cross-group buffer cap bypass") }
    catch let error as OperationError { #expect(error.code == .capacityExceeded) }
    for index in 1 ..< 8 {
      _ = try await first.claim(.init(scope: "script", key: String(index)), record: try await record(machine: "first-\(index)"))
      _ = try await second.claim(.init(scope: "script", key: String(index)), record: try await record(machine: "second-\(index)"))
    }
  }
}

extension MachineV2StoreTests {
  @Test func persistedPresenceEvidenceSurvivesReopenAndIsGroupFiltered() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let folder = try ScratchFolder("machine-v2-presence")
      let database = folder.url.appendingPathComponent("space.sqlite")
      let space = try Space.open(file: database)
      let machine = try await space.addMachine(name: "presence")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      let initial = try #require(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared))
      #expect(initial.state == .lost)
      #expect(initial.observedAt == Date(timeIntervalSince1970: 1_000_000_000))
      #expect(initial.reason == "neverAttached")
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .attached, description: description)
      let attached = try #require(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared))
      #expect(attached.state == .attached)
      #expect(attached.observedAt == Date(timeIntervalSince1970: 1_000_000_000))
      #expect(attached.reason == nil)
      time.withLock { $0 += 20 }
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .detached, reason: "leaving")
      let reopened = try Space.open(file: database)
      let detached = try #require(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared))
      #expect(detached.state == .detached)
      #expect(detached.observedAt == Date(timeIntervalSince1970: 1_000_000_020))
      #expect(detached.reason == "leaving")
      time.withLock { $0 += 1 }
      try await reopened.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .detached, reason: "leaving")
      #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == Date(timeIntervalSince1970: 1_000_000_021))
      #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .init(rawValue: "other")) == nil)
      #expect(try await reopened.machineV2PresenceEvidence("not-a-machine", group: .shared) == nil)
      time.withLock { $0 += 59 }
      try await reopened.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .lost, reason: "leaseSilence")
      let lost = try #require(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared))
      #expect(lost.state == .lost)
      #expect(lost.observedAt == Date(timeIntervalSince1970: 1_000_000_021))
      #expect(lost.reason == "leaseSilence")
      time.withLock { $0 += 20 }
      try await reopened.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .lost, reason: "leaseSilence")
      #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == lost.observedAt)
      time.withLock { $0 += 1 }
      try await reopened.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .attached, description: description)
      #expect(try await reopened.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == Date(timeIntervalSince1970: 1_000_000_101))
    }
  }

  @Test func malformedPresenceEvidenceIsTypedUnavailableRatherThanInventedStateOrDate() async throws {
    let space = try machineSpace()
    for (state, timestamp) in [("not-a-state", "2001-09-09 01:46:40.000"), ("detached", "not-a-timestamp")] {
      try await space.writer.write { db in
        let row = MachineV2PresenceRow(machineID: "corrupt", grp: "shared", state: state, description: nil, observedAt: timestamp, reason: "leaving")
        try MachineV2PresenceRow.upsert { row }.execute(db)
      }
      do { _ = try await space.machineV2PresenceEvidence("corrupt", group: .shared); Issue.record("malformed persisted presence accepted") }
      catch let error as OperationError { #expect(error.code == .storeUnavailable) }
      #expect(try await space.machineV2PresenceEvidence("corrupt", group: .init(rawValue: "other")) == nil)
    }
  }
}

extension MachineV2StoreTests {
  @Test func lostPresenceKeepsLastAnswerAcrossRepeatedProbesAndNeverAnsweredUsesRegistration() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 1_000_000_000))
    try await withDependencies { $0.date = .init { time.withLock { $0 } } } operation: {
      let space = try machineSpace()
      let machine = try await space.addMachine(name: "silence")
      try await space.registerMachineV2(machine.id.rawValue, group: .shared)
      time.withLock { $0 += 60 }
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .lost, reason: "leaseSilence")
      #expect(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == Date(timeIntervalSince1970: 1_000_000_000))
      time.withLock { $0 += 20 }
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .attached, description: description)
      time.withLock { $0 += 60 }
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .lost, reason: "leaseSilence")
      #expect(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == Date(timeIntervalSince1970: 1_000_000_080))
      time.withLock { $0 += 20 }
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .lost, reason: "transport")
      #expect(try await space.machineV2PresenceEvidence(machine.id.rawValue, group: .shared)?.observedAt == Date(timeIntervalSince1970: 1_000_000_080))
    }
  }
}

private func machineSpace() throws -> Space {
  try withDependencies { $0.continuousClock = ContinuousClock() } operation: { try Space.inMemory() }
}

private func storeMachine(_ name: String, space: Space) async throws -> String {
  if let machine = try await space.machine(named: name) { return machine.id.rawValue }
  return try await space.addMachineV2(name: name).machine.id.rawValue
}
