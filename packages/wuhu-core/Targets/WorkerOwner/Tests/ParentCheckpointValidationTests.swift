#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ParentCheckpointValidationTests {
  private let identity = ParentExecCheckpoint.Identity(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 123, birth: "fixture-process-birth")

  @Test func rawDuplicateKeysAreRejectedBeforeCodableCanCollapseThem() throws {
    let text = try String(decoding: fixture().encode(), as: UTF8.self)
    let duplicates = [
      "{\"version\":2," + text.dropFirst(),
      text.dropLast() + ",\"version\":2}",
      "{\"ver\\u0073ion\":2," + text.dropFirst(),
      text.replacingOccurrences(of: "\"identity\":{", with: "\"identity\":{\"space\":\"shadow\","),
      text.replacingOccurrences(of: "\"cursor\":{", with: "\"cursor\":{\"revision\":999,"),
      text.replacingOccurrences(of: "\"payload\":{", with: "\"payload\":{\"glob\":\"shadow\","),
    ]
    for duplicate in duplicates {
      #expect(duplicate != text)
      #expect(throws: WorkerProtocolError(.invalidConfiguration, message: "Invalid parent exec checkpoint")) {
        try ParentExecCheckpoint.decode(Data(duplicate.utf8), expecting: identity)
      }
    }
  }

  @Test func rawKeyScannerHandlesEscapesAndSeparateObjectScopes() throws {
    try ParentCheckpointJSON.validateKeys(Data(#"{"a":"escaped \"quote\" and \\ slash","b":[{"a":1},{"a":2}],"c":{"\u0061":3}}"#.utf8))
    #expect(throws: WorkerProtocolError.self) {
      try ParentCheckpointJSON.validateKeys(Data(#"{"outer":{"a":1,"\u0061":2}}"#.utf8))
    }
    #expect(throws: WorkerProtocolError.self) {
      try ParentCheckpointJSON.validateKeys(Data((String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513)).utf8))
    }
  }

  @Test func readerDefinitionsRequireUniqueProvenJournalReceipts() throws {
    let original = try fixture()
    let client = original.execution.receipts.clients[0]
    let reader = original.execution.readers[0]
    let journal = original.execution.receipts.identity
    func checkpoint(clients: [OwnerReceiptCheckpoint.Client], readers: [ScriptStreamCheckpoint]? = nil) -> ParentExecCheckpoint {
      ParentExecCheckpoint(identity: identity, execution: .init(receipts: .init(identity: journal, clients: clients), readers: readers ?? [reader]))
    }
    let consumed = OwnerReceiptCheckpoint.Client(id: client.id, consumed: 2, acknowledged: [], entries: [])
    let acknowledged = OwnerReceiptCheckpoint.Client(id: client.id, consumed: 0, acknowledged: [2], entries: [])
    for valid in [original, checkpoint(clients: [consumed]), checkpoint(clients: [acknowledged])] {
      _ = try ParentExecCheckpoint.decode(valid.encode(), expecting: identity)
    }
    try reject(checkpoint(clients: []))
    try reject(checkpoint(clients: [.init(id: UUID(), consumed: 2, acknowledged: [], entries: [])]))
    try reject(checkpoint(clients: [.init(id: client.id, consumed: 0, acknowledged: [], entries: [])]))
    let duplicateDefinition = WorkerCall(id: UUID(), operation: reader.definition.operation, payload: reader.definition.payload, traceContext: nil, receipt: reader.definition.receipt)
    try reject(checkpoint(clients: [consumed], readers: [reader, .init(definition: duplicateDefinition, reader: reader.reader)]))
    let changedCall = WorkerCall(id: reader.definition.id, operation: reader.definition.operation, payload: .null, traceContext: nil, receipt: reader.definition.receipt)
    let wrongReply = try WorkerReply(id: reader.definition.id, result: ownerEncode(OwnerEnvelope(value: ownerEncode(UUID()), fault: nil)))
    let failedReply = WorkerReply(id: reader.definition.id, error: .init(.remoteFailure, message: "private"))
    for entry in [
      OwnerReceiptCheckpoint.Entry(call: changedCall, reply: client.entries[0].reply),
      .init(call: reader.definition, reply: wrongReply),
      .init(call: reader.definition, reply: failedReply),
    ] {
      try reject(checkpoint(clients: [.init(id: client.id, consumed: 1, acknowledged: [], entries: [entry])]))
    }
  }

  @Test func watchCursorRequiresItsCompleteAcknowledgedMarkerShape() throws {
    let original = try fixture()
    let reader = original.execution.readers[0]
    let first: JSONValue = .object(["rev": .integer(0), "path": .string("/first")])
    let second: JSONValue = .object(["rev": .integer(0), "path": .string("/second")])
    func checkpoint(marker: JSONValue?, acknowledged: [JSONValue]) -> ParentExecCheckpoint {
      let state = ScriptReaderCheckpoint(cursor: .init(marker: marker, revision: 0, acknowledgedInRevision: acknowledged), stagedID: nil, stagedValue: nil, ended: false, overflowed: false)
      return ParentExecCheckpoint(identity: identity, execution: .init(receipts: original.execution.receipts, readers: [.init(definition: reader.definition, reader: state)]))
    }
    for valid in [checkpoint(marker: nil, acknowledged: []), checkpoint(marker: first, acknowledged: [first]), checkpoint(marker: second, acknowledged: [first, second])] {
      _ = try ParentExecCheckpoint.decode(valid.encode(), expecting: identity)
    }
    try reject(checkpoint(marker: nil, acknowledged: [first]))
    try reject(checkpoint(marker: first, acknowledged: []))
    try reject(checkpoint(marker: first, acknowledged: [first, second]))
  }

  private func fixture() throws -> ParentExecCheckpoint {
    let journal = UUID(), client = UUID()
    let definition = try WorkerCall(operation: "script.watch-open", payload: ownerEncode(WatchRequest(glob: "**", from: 0, session: .init("fixture"))), traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 2))
    let reply = try WorkerReply(id: definition.id, result: ownerEncode(OwnerEnvelope(value: ownerEncode(definition.id), fault: nil)))
    let receipts = OwnerReceiptCheckpoint(identity: journal, clients: [.init(id: client, consumed: 1, acknowledged: [], entries: [.init(call: definition, reply: reply)])])
    let state = ScriptReaderCheckpoint(cursor: .init(revision: 0), stagedID: nil, stagedValue: nil, ended: false, overflowed: false)
    return ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: [.init(definition: definition, reader: state)]))
  }

  private func reject(_ checkpoint: ParentExecCheckpoint) throws {
    #expect(throws: WorkerProtocolError.self) { try checkpoint.execution.validate() }
    let value: JSONValue = try .object(["version": .integer(1), "identity": ownerEncode(identity), "execution": ownerEncode(checkpoint.execution)])
    let data = try JSONEncoder().encode(value)
    #expect(throws: WorkerProtocolError(.invalidConfiguration, message: "Invalid parent exec checkpoint")) {
      try ParentExecCheckpoint.decode(data, expecting: identity)
    }
  }
}
