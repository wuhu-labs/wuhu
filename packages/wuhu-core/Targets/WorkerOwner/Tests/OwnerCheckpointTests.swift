#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct OwnerCheckpointTests {
  @Test func pauseDrainsAdmittedEffectsButRefusesNewAdmissionAndPrematureCheckpoint() async throws {
    let journal = OwnerReceiptJournal()
    let client = UUID()
    let first = WorkerCall(operation: "fixture.write", payload: .integer(1), receipt: .init(endpoint: journal.identity, client: client, sequence: 1))
    let next = WorkerCall(operation: "fixture.write", payload: .integer(2), receipt: .init(endpoint: journal.identity, client: client, sequence: 2))
    let effects = Mutex(0)
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let pending = Task {
      try await journal.run(first) {
        effects.withLock { $0 += 1 }
        signal.yield(())
        for await _ in release {}
        return .integer(7)
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    let token = try await journal.pauseAdmission()
    #expect(try await journal.pauseAdmission() == token)
    await #expect(throws: WorkerProtocolError.self) { try await journal.checkpoint(token) }
    await #expect(throws: WorkerProtocolError.self) {
      _ = try await journal.run(next) { Issue.record("Paused journal admitted another effect"); return .null }
    }
    let duplicate = Task { try await journal.run(first) { Issue.record("Duplicate effect admitted while paused"); return .null } }
    let draining = Task { try await journal.quiesce(token) }
    finish.finish()
    #expect(try await pending.value.result == .integer(7))
    #expect(try await duplicate.value.result == .integer(7))
    #expect(try await draining.value.isEmpty)
    #expect(effects.withLock { $0 } == 1)
    #expect(try await journal.checkpoint(token).clients.first?.entries.count == 1)
    try await journal.resumeAdmission(token)
    #expect(try await journal.run(next) { .integer(8) }.result == .integer(8))
    await journal.stop()
  }

  @Test func roundTripRetainsExactRepliesAndAcknowledgementFencesBeforeOpeningAdmission() async throws {
    let journal = OwnerReceiptJournal()
    let client = UUID()
    let calls = (1 ... 3).map { sequence in
      WorkerCall(operation: "fixture.write", payload: .integer(sequence), receipt: .init(endpoint: journal.identity, client: client, sequence: sequence))
    }
    for call in calls { _ = try await journal.run(call) { .null } }
    try await journal.acknowledge(calls[2].receipt!)
    let token = try await journal.pauseAdmission()
    let checkpoint = try await journal.checkpoint(token)
    let decoded = try JSONDecoder().decode(OwnerReceiptCheckpoint.self, from: JSONEncoder().encode(checkpoint))
    let restored = try OwnerReceiptJournal(restoring: decoded)
    #expect(restored.identity == journal.identity)
    #expect(try await restored.run(calls[0]) { Issue.record("Transferred effect replayed"); return .integer(9) }.result == .null)
    try await restored.acknowledge(calls[0].receipt!)
    await #expect(throws: WorkerProtocolError.self) { _ = try await restored.run(calls[0]) { .null } }
    await #expect(throws: WorkerProtocolError.self) { _ = try await restored.run(calls[2]) { .null } }
    let next = WorkerCall(operation: "fixture.write", receipt: .init(endpoint: journal.identity, client: client, sequence: 4))
    await #expect(throws: WorkerProtocolError.self) { _ = try await restored.run(next) { .null } }
    try await restored.acknowledge(calls[1].receipt!)
    let restoreToken = try await restored.pauseAdmission()
    let consumed = try await restored.checkpoint(restoreToken)
    #expect(consumed.clients.first?.consumed == 3)
    #expect(consumed.clients.first?.acknowledged.isEmpty == true)
    #expect(consumed.clients.first?.entries.isEmpty == true)
    try await restored.resumeAdmission(restoreToken)
    #expect(try await restored.run(next) { .bool(true) }.result == .bool(true))
    await journal.stop(); await restored.stop()
  }

  @Test func idleReaderWaitsAreReportedInsteadOfBlockingEffectDrainOrEnteringCheckpoint() async throws {
    let journal = OwnerReceiptJournal()
    let call = WorkerCall(operation: "script.stream-next", receipt: .init(endpoint: journal.identity, client: UUID(), sequence: 1))
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let reader = Task {
      try await journal.run(call) {
        signal.yield(())
        for await _ in release {}
        return .null
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    let token = try await journal.pauseAdmission()
    let remaining = try await journal.quiesce(token, excluding: ["script.stream-next"])
    #expect(remaining.map(\.id) == [call.id])
    #expect(remaining.first?.terminal == false)
    await #expect(throws: WorkerProtocolError.self) { try await journal.checkpoint(token) }
    finish.finish()
    _ = try await reader.value
    #expect(try await journal.quiesce(token).isEmpty)
    #expect(try await journal.checkpoint(token).clients.first?.entries.count == 1)
    await journal.stop()
  }

  @Test func resumedOrStoppedPauseCannotAuthorizeAReplacementCheckpoint() async throws {
    let journal = OwnerReceiptJournal()
    let first = try await journal.pauseAdmission()
    try await journal.resumeAdmission(first)
    let second = try await journal.pauseAdmission()
    #expect(first != second)
    await #expect(throws: WorkerProtocolError.self) { try await journal.quiesce(first) }
    await #expect(throws: WorkerProtocolError.self) { try await journal.checkpoint(first) }
    await #expect(throws: WorkerProtocolError.self) { try await journal.resumeAdmission(first) }
    _ = try await journal.checkpoint(second)
    await journal.stop()
    await #expect(throws: WorkerProtocolError.self) { try await journal.checkpoint(second) }
    await #expect(throws: WorkerProtocolError.self) { try await journal.pauseAdmission() }
  }

  @Test func malformedCheckpointNeverCreatesAnAdoptableJournal() async throws {
    let identity = UUID(), client = UUID()
    let call = WorkerCall(operation: "fixture.write", receipt: .init(endpoint: identity, client: client, sequence: 1))
    let entry = OwnerReceiptCheckpoint.Entry(call: call, reply: .init(id: call.id, result: .null))
    let valid = OwnerReceiptCheckpoint.Client(id: client, consumed: 0, acknowledged: [], entries: [entry])
    let invalid: [OwnerReceiptCheckpoint] = [
      .init(identity: UUID(), clients: [valid]),
      .init(identity: identity, clients: [valid, valid]),
      .init(identity: identity, clients: [.init(id: UUID(), consumed: 0, acknowledged: [], entries: [entry])]),
      .init(identity: identity, clients: [.init(id: client, consumed: 1, acknowledged: [], entries: [entry])]),
      .init(identity: identity, clients: [.init(id: client, consumed: -1, acknowledged: [], entries: [])]),
      .init(identity: identity, clients: [.init(id: client, consumed: 0, acknowledged: [1025], entries: [])]),
      .init(identity: identity, clients: [.init(id: client, consumed: 0, acknowledged: [1], entries: [])]),
      .init(identity: identity, clients: [.init(id: client, consumed: 0, acknowledged: [], entries: [entry, entry])]),
      .init(identity: identity, clients: [.init(id: client, consumed: 0, acknowledged: [], entries: [.init(call: call, reply: .init(id: UUID(), result: .null))])]),
    ]
    for checkpoint in invalid {
      #expect(throws: WorkerProtocolError.self) { try OwnerReceiptJournal(restoring: checkpoint) }
    }
  }

  @Test func finalCheckpointSealsAcknowledgementsUntilRollback() async throws {
    let journal = OwnerReceiptJournal()
    let call = WorkerCall(operation: "fixture.write", receipt: .init(endpoint: journal.identity, client: UUID(), sequence: 1))
    _ = try await journal.run(call) { .integer(1) }
    let token = try await journal.pauseAdmission()
    let snapshot = try await journal.checkpoint(token)
    do { try await journal.acknowledge(call.receipt!); Issue.record("Acknowledgement changed a sealed handoff") }
    catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
    #expect(try await journal.checkpoint(token).clients.first?.entries.count == snapshot.clients.first?.entries.count)
    try await journal.resumeAdmission(token)
    try await journal.acknowledge(call.receipt!)
    #expect(await journal.inventory().isEmpty)
    await journal.stop()
  }
}
