#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.serialized, .timeLimit(.minutes(3))) struct ParentExecCheckpointTests {
  private let identity = ParentExecCheckpoint.Identity(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 123, birth: "fixture-process-birth")

  @Test func roundTripRetainsRepliesFencesAndStagedWatchAcknowledgements() async throws {
    let original = try fixture()
    let restored = try ParentExecCheckpoint.decode(original.encode(), expecting: identity)
    #expect(String(describing: restored) == "ParentExecCheckpoint(<redacted>)")
    #expect(String(reflecting: restored) == "ParentExecCheckpoint(<redacted>)")
    #expect(Mirror(reflecting: restored).children.isEmpty)
    let before = original.execution.receipts.clients[0]
    let after = restored.execution.receipts.clients[0]
    #expect(after.consumed == 1)
    #expect(after.acknowledged == [3])
    #expect(after.entries.map(\.call) == before.entries.map(\.call))
    #expect(after.entries.map(\.reply) == before.entries.map(\.reply))
    let journal = try OwnerReceiptJournal(restoring: restored.execution.receipts)
    for entry in after.entries {
      #expect(try await journal.run(entry.call) { Issue.record("Imported effect replayed"); return .null } == entry.reply)
    }
    let consumed = WorkerCall(operation: "fixture.write", receipt: .init(endpoint: journal.identity, client: after.id, sequence: 1))
    let acknowledged = WorkerCall(operation: "fixture.write", receipt: .init(endpoint: journal.identity, client: after.id, sequence: 3))
    for call in [consumed, acknowledged] {
      await #expect(throws: WorkerProtocolError.self) { _ = try await journal.run(call) { .null } }
    }
    let reader = restored.execution.readers[0].reader
    let stream = try RetainedScriptStream(source: { cursor in
      #expect(cursor.revision == 5)
      #expect(cursor.acknowledgedInRevision.count == 2)
      return AsyncThrowingStream { $0.yield(.integer(9)); $0.finish() }
    }, checkpoint: reader, overflow: .init())
    await stream.resume()
    await #expect(throws: WorkerProtocolError.self) { _ = try await stream.next(UUID()) }
    await stream.acknowledge(reader.stagedID!)
    #expect(try await stream.next(UUID()).value == .integer(9))
    try await journal.acknowledge(after.entries[0].call.receipt!)
    let token = try await journal.pauseAdmission()
    #expect(try await journal.checkpoint(token).clients[0].consumed == 3)
    await stream.cancel(); await journal.stop()
  }

  @Test(arguments: [false, true]) func queryEndAndWatchOverflowAreNotReset(watch: Bool) async throws {
    let journal = UUID()
    let definition = try WorkerCall(
      operation: watch ? "script.watch-open" : "script.observe-open",
      payload: watch
        ? ownerEncode(WatchRequest(glob: "**", from: nil, session: .init("fixture")))
        : ownerEncode(ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: .init("fixture"))),
      traceContext: nil,
      receipt: .init(endpoint: journal, client: UUID(), sequence: 1),
    )
    let marker: JSONValue = watch ? .object(["rev": .integer(7)]) : .array([.string("latest-query-snapshot")])
    let reader = ScriptReaderCheckpoint(cursor: .init(marker: marker, revision: watch ? 7 : nil, acknowledgedInRevision: watch ? [marker] : []), stagedID: nil, stagedValue: nil, ended: !watch, overflowed: watch)
    let checkpoint = ParentExecCheckpoint(identity: identity, execution: .init(receipts: .init(identity: journal, clients: [.init(id: definition.receipt!.client, consumed: 1, acknowledged: [], entries: [])]), readers: [.init(definition: definition, reader: reader)]))
    let restored = try ParentExecCheckpoint.decode(checkpoint.encode(), expecting: identity).execution.readers[0].reader
    #expect(restored.cursor.marker == marker)
    #expect(restored.cursor.revision == reader.cursor.revision)
    #expect(restored.ended == !watch)
    #expect(restored.overflowed == watch)
    let stream = try RetainedScriptStream(source: { _ in
      Issue.record("Ended/overflowed reader reopened its source")
      return AsyncThrowingStream { $0.finish() }
    }, checkpoint: restored, overflow: .init())
    await stream.resume()
    await #expect(throws: WorkerProtocolError.self) { _ = try await stream.next(UUID()) }
    await stream.cancel()
  }

  @Test func unknownFieldsAtEveryStructuralLayerFailClosed() throws {
    let data = try fixture().encode()
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    let paths = [
      [], ["identity"], ["execution"], ["execution", "receipts"],
      ["execution", "receipts", "clients", "0"],
      ["execution", "receipts", "clients", "0", "entries", "0"],
      ["execution", "receipts", "clients", "0", "entries", "0", "call"],
      ["execution", "receipts", "clients", "0", "entries", "0", "call", "receipt"],
      ["execution", "receipts", "clients", "0", "entries", "0", "reply"],
      ["execution", "receipts", "clients", "0", "entries", "1", "reply", "error"],
      ["execution", "readers", "0"], ["execution", "readers", "0", "definition"],
      ["execution", "readers", "0", "definition", "receipt"],
      ["execution", "readers", "0", "reader"], ["execution", "readers", "0", "reader", "cursor"],
    ]
    for path in paths {
      let changed = replacing(value, at: path) { object in
        guard case var .object(fields) = object else { preconditionFailure() }
        fields["future-private-field"] = .string("must-not-appear-in-error")
        return .object(fields)
      }
      let bad = try JSONEncoder().encode(changed)
      #expect(throws: WorkerProtocolError(.invalidConfiguration, message: "Invalid parent exec checkpoint")) {
        try ParentExecCheckpoint.decode(bad, expecting: identity)
      }
    }
  }

  @Test func unsupportedVersionForeignIdentityAndMalformedCorrelationsAreRejected() throws {
    let data = try fixture().encode()
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    for version in [0, 2, Int.max] {
      let changed = replacing(value, at: ["version"]) { _ in .integer(version) }
      #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(JSONEncoder().encode(changed), expecting: identity) }
    }
    let foreign = [
      ParentExecCheckpoint.Identity(space: "other", generation: identity.generation, incarnation: identity.incarnation, processID: identity.processID, birth: identity.birth),
      .init(space: identity.space, generation: UUID(), incarnation: identity.incarnation, processID: identity.processID, birth: identity.birth),
      .init(space: identity.space, generation: identity.generation, incarnation: UUID(), processID: identity.processID, birth: identity.birth),
      .init(space: identity.space, generation: identity.generation, incarnation: identity.incarnation, processID: 124, birth: identity.birth),
      .init(space: identity.space, generation: identity.generation, incarnation: identity.incarnation, processID: identity.processID, birth: "another-process-birth"),
    ]
    for identity in foreign {
      #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(data, expecting: identity) }
    }
    for path in [
      ["execution", "readers", "0", "reader", "stagedValue"],
      ["execution", "receipts", "identity"],
    ] {
      let changed = replacing(value, at: path) { _ in .string(UUID().uuidString) }
      #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(JSONEncoder().encode(changed), expecting: identity) }
    }
    #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(Data(data.dropLast()), expecting: identity) }
    #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(Data("{}".utf8), expecting: identity) }
  }

  @Test func exportRequiresPreparedStateAndFailureLeavesOriginalResumable() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    await #expect(throws: WorkerProtocolError.self) { try await source.execCheckpoint(identity: identity) }
    try await source.prepare()
    let bad = ParentExecCheckpoint.Identity(space: "", generation: identity.generation, incarnation: identity.incarnation, processID: 0, birth: "")
    await #expect(throws: WorkerProtocolError.self) { try await source.execCheckpoint(identity: bad) }
    let data = try await source.execCheckpoint(identity: identity)
    #expect(try ParentExecCheckpoint.decode(data, expecting: identity).execution.readers.isEmpty)
    try await source.resume()
    await #expect(throws: WorkerProtocolError.self) { try await source.execCheckpoint(identity: identity) }
    await source.shutdown()
    await #expect(throws: WorkerProtocolError.self) { try await source.execCheckpoint(identity: identity) }
  }

  @Test func exactEncodedByteLimitIsAcceptedAndOneByteMoreIsRefused() throws {
    let journal = UUID(), client = UUID(), id = UUID()
    func checkpoint(payload: String, reply: String) -> ParentExecCheckpoint {
      let call = WorkerCall(id: id, operation: "fixture.write", payload: .string(payload), traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 1))
      let receipts = OwnerReceiptCheckpoint(identity: journal, clients: [.init(id: client, consumed: 0, acknowledged: [], entries: [.init(call: call, reply: .init(id: id, result: .string(reply)))])])
      return ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: []))
    }
    let overhead = try checkpoint(payload: "", reply: "").encode().count
    let input = String(repeating: "x", count: (64 << 20) - 2)
    let output = String(repeating: "y", count: ParentExecCheckpoint.maximumBytes - overhead - input.utf8.count)
    let data = try checkpoint(payload: input, reply: output).encode()
    #expect(data.count == ParentExecCheckpoint.maximumBytes)
    let restored = try ParentExecCheckpoint.decode(data, expecting: identity)
    #expect(restored.execution.receipts.clients[0].entries[0].call.payload == .string(input))
    #expect(restored.execution.receipts.clients[0].entries[0].reply.result == .string(output))
    var oversized = data
    oversized.append(32)
    #expect(throws: WorkerProtocolError(.capacityExceeded, message: "Parent exec checkpoint exceeds its byte limit")) {
      try ParentExecCheckpoint.decode(oversized, expecting: identity)
    }
    #expect(throws: WorkerProtocolError(.capacityExceeded, message: "Parent exec checkpoint exceeds its byte limit")) {
      try checkpoint(payload: input, reply: output + "y").encode()
    }
  }

  private func fixture() throws -> ParentExecCheckpoint {
    let journal = UUID(), client = UUID(), stream = UUID()
    let first: JSONValue = .object(["rev": .integer(5), "path": .string("/one.md")])
    let staged: JSONValue = .object(["rev": .integer(5), "path": .string("/two.md"), "opaque": .object(["arbitrary-data-field": .bool(true)])])
    let definition = try WorkerCall(id: stream, operation: "script.watch-open", payload: ownerEncode(WatchRequest(glob: "**", from: nil, session: .init("fixture"))), traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 1))
    let pull = try WorkerCall(operation: "script.stream-next", payload: ownerEncode(StreamRequest(id: stream)), traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 2))
    let reply = try WorkerReply(id: pull.id, result: ownerEncode(OwnerEnvelope(value: ownerEncode(OwnerRecord(value: staged, fault: nil, ended: false)), fault: nil)))
    let failed = WorkerCall(operation: "fixture.write", traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 4))
    let receipts = OwnerReceiptCheckpoint(identity: journal, clients: [.init(id: client, consumed: 1, acknowledged: [3], entries: [.init(call: pull, reply: reply), .init(call: failed, reply: .init(id: failed.id, error: .init(.remoteFailure, message: "private-error")))])])
    let reader = ScriptReaderCheckpoint(cursor: .init(marker: first, revision: 5, acknowledgedInRevision: [first]), stagedID: pull.id, stagedValue: staged, ended: false, overflowed: false)
    return ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: [.init(definition: definition, reader: reader)]))
  }

  private func replacing(_ value: JSONValue, at path: [String], transform: (JSONValue) -> JSONValue) -> JSONValue {
    guard let key = path.first else { return transform(value) }
    let rest = Array(path.dropFirst())
    switch value {
    case var .object(fields):
      fields[key] = replacing(fields[key]!, at: rest, transform: transform)
      return .object(fields)
    case var .array(values):
      let index = Int(key)!
      values[index] = replacing(values[index], at: rest, transform: transform)
      return .array(values)
    default: preconditionFailure()
    }
  }
}
