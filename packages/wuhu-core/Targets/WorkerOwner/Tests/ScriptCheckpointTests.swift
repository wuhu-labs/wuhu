#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ScriptCheckpointTests {
  @Test(arguments: [false, true]) func watchReplyAndOtherEventsInItsRevisionSurviveRestore(acknowledged: Bool) async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "checkpoint", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let owner = InProcessToolOwnerClient(space: space)
    let streams = ParentScriptStreams()
    let journal = OwnerReceiptJournal()
    let client = UUID()
    let definition = try WorkerCall(operation: "script.watch-open", payload: ownerEncode(WatchRequest(glob: "**", from: nil, session: session)), receipt: .init(endpoint: journal.identity, client: client, sequence: 1))
    let id = try await streams.open(definition, owner: owner)
    _ = try await space.fs(.shared).write("/events/first.md", Data("first".utf8), ifMatch: nil)
    let first = try await space.currentRevision()
    _ = try await space.fs(.shared).write("/events/second.md", Data("second".utf8), ifMatch: nil)
    let second = try await space.currentRevision()
    let pull = try WorkerCall(operation: "script.stream-next", payload: ownerEncode(StreamRequest(id: id)), receipt: .init(endpoint: journal.identity, client: client, sequence: 1))
    let original = try await journal.run(pull) { try await ownerEncode(streams.next(id, call: pull.id)) }
    let record = try ownerDecode(OwnerRecord.self, original.result!)
    #expect(record.value?.object?["rev"]?.intValue == first)
    if acknowledged {
      try await journal.acknowledge(pull.receipt!)
      await streams.acknowledge(pull)
    }
    let token = try await journal.pauseAdmission()
    try await streams.suspend()
    #expect(try await journal.quiesce(token).isEmpty)
    let receiptCheckpoint = try await journal.checkpoint(token)
    let readerCheckpoint = try await streams.checkpoint(retaining: acknowledged ? [] : [pull.id])
    let encoded = try JSONEncoder().encode(readerCheckpoint)
    let restoredStreams = ParentScriptStreams()
    try await restoredStreams.restore(JSONDecoder().decode([ScriptStreamCheckpoint].self, from: encoded), owner: owner)
    let restoredJournal = try OwnerReceiptJournal(restoring: receiptCheckpoint)
    if !acknowledged {
      let replay = try await restoredJournal.run(pull) { Issue.record("Watch pull was replayed instead of recovering its retained reply"); return .null }
      #expect(replay.result == original.result)
      try await restoredJournal.acknowledge(pull.receipt!)
      await restoredStreams.acknowledge(pull)
    }
    await restoredStreams.resume()
    let remainingCall = try WorkerCall(operation: "script.stream-next", payload: ownerEncode(StreamRequest(id: id)))
    let remaining = try await restoredStreams.next(id, call: remainingCall.id)
    #expect(remaining.value?.object?["rev"]?.intValue == first)
    #expect(remaining.value != record.value)
    await restoredStreams.acknowledge(remainingCall)
    let after = try await restoredStreams.next(id, call: UUID())
    #expect(after.value?.object?["rev"]?.intValue == second)
    await streams.stop(); await restoredStreams.stop(); await journal.stop(); await restoredJournal.stop()
  }

  @Test func idleReadSuspendsWithoutEndingAndCanResumeOnTheOldOwner() async throws {
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (idle, _) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
    let source = AsyncThrowingStream<JSONValue, any Error>(unfolding: {
      signal.yield(())
      var iterator = idle.makeAsyncIterator()
      return try await iterator.next()
    })
    let stream = RetainedScriptStream(source: { _ in AsyncThrowingStream { $0.yield(.integer(9)); $0.finish() } }, reader: OwnerRecordReader(.stream(OwnerRecordSequence(source: source))), cursor: ScriptStreamCursor())
    let pending = Task { try await stream.next(UUID()) }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await stream.suspend()
    let suspended = try await pending.value
    #expect(suspended.suspended == true)
    #expect(!suspended.ended)
    let checkpoint = try await stream.checkpoint(retaining: [])
    #expect(!checkpoint.ended)
    await stream.resume()
    #expect(try await stream.next(UUID()).value == .integer(9))
    await stream.cancel()
  }

  @Test func checkpointReconcilesAnAckBeforeItsReaderCallback() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "ack", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let streams = ParentScriptStreams()
    let definition = try WorkerCall(operation: "script.observe-open", payload: ownerEncode(ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: session)), receipt: .init(endpoint: UUID(), client: UUID(), sequence: 1))
    let id = try await streams.open(definition, owner: InProcessToolOwnerClient(space: space))
    let record = try await streams.next(id, call: UUID())
    try await streams.suspend()
    let checkpoints = try await streams.checkpoint(retaining: [])
    #expect(checkpoints.first?.reader.cursor.marker == record.value)
    #expect(checkpoints.first?.reader.stagedID == nil)
    await streams.stop()
  }

  @Test func overflowCannotBeClearedBySuspendingOrRestoringAWatch() async throws {
    let overflow = ScriptWatchOverflow()
    let (overflowed, signal) = AsyncStream<Void>.makeStream()
    let counter = Mutex(0)
    let values = AsyncThrowingStream<JSONValue, any Error>(unfolding: {
      .integer(counter.withLock { $0 += 1; return $0 })
    })
    let bounded = boundedScriptWatch(values, onOverflow: { overflow.mark(); signal.finish() })
    let source: RetainedScriptStream.Source = { _ in
      Issue.record("Overflowed watch was reopened")
      return AsyncThrowingStream { $0.finish() }
    }
    let reader = OwnerRecordReader<JSONValue>(.stream(OwnerRecordSequence(source: bounded)))
    let stream = RetainedScriptStream(source: source, reader: reader, cursor: ScriptStreamCursor(revision: 0), overflow: overflow)
    for await _ in overflowed {}
    await stream.suspend()
    let checkpoint = try await stream.checkpoint(retaining: [])
    #expect(checkpoint.overflowed)
    let restored = try RetainedScriptStream(source: source, checkpoint: checkpoint, overflow: ScriptWatchOverflow())
    for candidate in [stream, restored] {
      await candidate.resume()
      do { _ = try await candidate.next(UUID()); Issue.record("Watch overflow was cleared") }
      catch let error as WorkerProtocolError { #expect(error.code == .capacityExceeded) }
      await candidate.cancel()
    }
  }

  @Test func remoteSuspensionRetriesOnlyTheExplicitReadMarker() async throws {
    let reads = Mutex(0)
    let bytes = OwnerByteEndpoint(invoke: { _ in
      let count = reads.withLock { $0 += 1; return $0 }
      let record = count == 1
        ? OwnerRecord(value: nil, fault: nil, ended: false, suspended: true)
        : OwnerRecord(value: .integer(7), fault: nil, ended: false)
      return try ownerEncode(OwnerEnvelope(value: ownerEncode(record), fault: nil))
    })
    let endpoint = try bytes.endpoint(token: "fixture", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let stream = RemoteScriptStream<Int>(rpc: OwnerRPC(client: client), id: UUID())
    #expect(try await stream.next() == 7)
    #expect(reads.withLock { $0 } == 2)
    #expect(await client.pendingReceipts().isEmpty)
    await bytes.shutdown()
  }
}
