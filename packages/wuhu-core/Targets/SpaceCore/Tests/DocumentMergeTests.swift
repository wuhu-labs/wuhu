import ControlledTime
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import LiveDocument
import Loro
import Scratch
@testable import SpaceCore
import SpaceFS
import Synchronization
import Testing
import WmdDocument

@Suite(.deterministicDependencies)
struct DocumentMergeTests {
  private let plan = "/notes/plan.wmd"

  @Test func addingHistoryIdentitiesPreservesAnExistingDocument() async throws {
    let folder = try ScratchFolder("document-history-upgrade")
    let file = folder.url.appending(path: "space.sqlite")
    let first = try Space.open(file: file)
    _ = try await first.fs(.shared).write(plan, bytes("Before the migration\n"), ifMatch: nil)
    try await first.close()
    let old = try DatabaseQueue(path: file.path)
    try await old.write { db in
      try db.execute(sql: "ALTER TABLE document_state DROP COLUMN history")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '039'")
    }
    try old.close()
    let migrated = try Space.open(file: file)
    let client = try await DocumentClient.join(migrated, plan)
    #expect(client.replica.text == "Before the migration\n")
    let material = try await migrated.documents.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
    #expect(try #require(material.history).count == 32)
    #expect(text(try await migrated.fs(.shared).read(plan).1) == "Before the migration\n")
    try await migrated.close()
  }

  @Test(arguments: [true, false])
  func aClientSnapshotCannotShortenAParkedWritesHistory(_ shallow: Bool) async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes(""), ifMatch: nil)
    var client = try await DocumentClient.join(space, plan)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let before = try await hub.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("Agent\n")), base: .latest, createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    _ = try #require(await started.next())
    let source = LiveReplica(.wmd)
    let edit = try #require(try source.merge(text: "Socket\n", base: nil, peer: 99))
    try source.importUpdate(edit.update)
    let doc = LoroDoc()
    _ = try doc.import(bytes: source.snapshot())
    let snapshot = try doc.export(mode: shallow ? .shallowSnapshot(frontiers: doc.oplogFrontiers()) : .snapshot)
    let raw = LiveReplica(.wmd)
    try raw.importUpdate(snapshot)
    let imported = LoroDoc()
    _ = try imported.import(bytes: raw.snapshot())
    #expect(imported.isShallow() == shallow)
    client.send(.update(Array(snapshot)))
    if shallow {
      guard case .control(.error(code: .invalidUpdate, _)) = await client.next() else { Issue.record("a shallow client snapshot was accepted"); return }
      #expect(await client.next() == nil)
      let after = try await hub.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
      #expect(after.history == before.history)
      #expect(after.snapshot == before.snapshot)
      #expect(after.updates == before.updates)
      #expect(after.base == before.base)
      var rebuilt = try await DocumentClient.join(space, plan, peer: "2")
      #expect(rebuilt.replica.text.isEmpty)
      try rebuilt.edit("Honest\n")
      #expect(await rebuilt.next() == .control(.ack(count: 1)))
    } else {
      #expect(await client.next() == .control(.ack(count: 1)))
    }
    await hub.checkpoint(.shared, try SpacePath(validating: plan))
    gate.release.yield(())
    let wrote = try await writing.value
    let result = try await fs.read(plan)
    #expect(result.0.rev == Int(wrote))
    let final = text(result.1)
    #expect(final.contains("Agent"))
    #expect(final.contains("Socket") == !shallow)
    #expect(final.contains("Honest") == shallow)
  }

  @Test func aCurrentRevisionRemainsAnAuthoritativeStepPrecondition() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let read = try await fs.write(plan, bytes("# A\n\none\n"), ifMatch: nil)
    var client = try await DocumentClient.join(space, plan)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("# B\n\none\n")), base: .current(Int64(read.rev!)), createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    _ = try #require(await started.next())
    try client.edit("# A\n\ntwo\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    await hub.checkpoint(.shared, try SpacePath(validating: plan))
    guard case .control(.checkpoint) = await client.next() else { Issue.record("no checkpoint"); return }
    gate.release.yield(())
    await #expect(throws: SpaceError.versionMismatch(plan)) { try await writing.value }
    #expect(text(try await fs.read(plan).1) == "# A\n\ntwo\n")
  }

  @Test(arguments: [0, 1, 2])
  func aPreparedWriteImportsIntoLaterTypingAndCheckpoints(_ checkpoint: Int) async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let read = try await fs.write(plan, bytes("# A\n\none\n"), ifMatch: nil)
    var client = try await DocumentClient.join(space, plan)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("# B\n\none\n")), base: .read(Int64(read.rev!)), createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    let prepared = try #require(await started.next())
    if checkpoint == 2 {
      try client.edit("# A\n\none!\n")
      #expect(await client.next() == .control(.ack(count: 1)))
      try client.edit("# A\n\none\n")
    } else { try client.edit("# A\n\ntwo\n") }
    #expect(await client.next() == .control(.ack(count: 1)))
    if checkpoint != 0 {
      await hub.checkpoint(.shared, try SpacePath(validating: plan))
      guard case let .control(.checkpoint(rev)) = await client.next() else { Issue.record("no checkpoint"); return }
      if checkpoint == 2 { #expect(rev == read.rev) }
    }
    let later = try await hub.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
    guard case let .current(identity) = prepared.history else { Issue.record("not a warm preparation"); return }
    #expect(later.history == identity)
    gate.release.yield(())
    let wrote = try await writing.value
    guard case let .frame(.update(update)) = await client.next() else { Issue.record("no prepared update"); return }
    try client.replica.importUpdate(Data(update))
    let expected = checkpoint == 2 ? "# B\n\none\n" : "# B\n\ntwo\n"
    #expect(client.replica.text == expected)
    #expect(await client.next() == .control(.checkpoint(rev: Int(wrote))))
    #expect(text(try await fs.read(plan).1) == expected)
  }

  @Test func aGatedHostMergeLeavesTheWriterFreeAndANilUpdateStillCommitsTyping() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    var client = try await DocumentClient.join(space, plan)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let finished = Mutex(false)
    let writing = Task { [hub] in
      let rev = try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("One\n")), base: .latest, createOnly: false, acting: .shared, attribution: nil)
      finished.withLock { $0 = true }
      return rev
    }
    defer { gate.release.yield(()) }
    #expect(try #require(await started.next()).update == nil)
    _ = try await fs.write("/unrelated.txt", bytes("the writer is free\n"), ifMatch: nil)
    #expect(!finished.withLock { $0 })
    try client.edit("Two\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    gate.release.yield(())
    let wrote = try await writing.value
    #expect(await client.next() == .control(.checkpoint(rev: Int(wrote))))
    #expect(text(try await fs.read(plan).1) == "Two\n")
  }

  @Test func aPreparedReadCannotImportAcrossAMoveToAnotherHistory() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let read = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("Two\n")), base: .read(Int64(read.rev!)), createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    _ = await started.next()
    try await fs.move(plan, to: "/moved.wmd")
    gate.release.yield(())
    await #expect(throws: SpaceError.versionMismatch(plan)) { try await writing.value }
    #expect(text(try await fs.read("/moved.wmd").1) == "One\n")
    await #expect(throws: SpaceError.notFound(plan)) { try await fs.read(plan) }
  }

  @Test(arguments: [false, true])
  func aColdSeedLosesToAHistoryCreatedWhileItMerged(_ createOnly: Bool) async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("Agent\n")), base: .latest, createOnly: createOnly, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    guard case .seed = try #require(await started.next()).history else { Issue.record("not a cold seed"); return }
    _ = try await fs.write(plan, bytes("Racing create\n"), ifMatch: nil)
    let live = try await hub.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
    gate.release.yield(())
    if createOnly {
      await #expect(throws: SpaceError.alreadyExists(plan)) { try await writing.value }
      #expect(text(try await fs.read(plan).1) == "Racing create\n")
      return
    }
    guard case let .current(identity) = try #require(await started.next()).history else { Issue.record("did not re-read"); return }
    #expect(identity == live.history)
    gate.release.yield(())
    _ = try await writing.value
    #expect(text(try await fs.read(plan).1) == "Agent\n")
    let final = try await hub.rows.material(.shared, SpacePath(validating: plan), base: .latest, createOnly: false)
    #expect(final.history == live.history)
  }

  @Test func threeReplacedHistoriesRefuseWithoutAMergeInTheStep() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Original\n"), ifMatch: nil)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await space.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("Agent\n")), base: .latest, createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    for attempt in 1 ... 3 {
      _ = try #require(await started.next())
      _ = try await fs.write("/replacement.md", bytes("Replacement \(attempt)\n"), ifMatch: nil)
      try await space.move("/replacement.md", in: .shared, to: plan, in: .shared, replacing: true, acting: .shared)
      gate.release.yield(())
    }
    await #expect(throws: SpaceError.liveBusy(plan)) { try await writing.value }
    #expect(text(try await fs.read(plan).1) == "Replacement 3\n")
  }

  @Test func aMergePreparedByTheNextWorkerImportsOnceAfterTheOwnerDrains() async throws {
    let folder = try ScratchFolder("prepared-document-rollover")
    let file = folder.url.appending(path: "space.sqlite")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space.open(file: file), Space.open(file: file))
    }
    _ = try await first.fs(.shared).write(plan, bytes("# A\n\none\n"), ifMatch: nil)
    var old = try await DocumentClient.join(first, plan)
    let gate = MergeGate()
    var started = gate.started.makeAsyncIterator()
    var hub = await second.documents
    hub.merge = gate.client
    let writing = Task { [hub] in
      try await hub.write(.shared, SpacePath(validating: plan), Data(bytes("# B\n\none\n")), base: .latest, createOnly: false, acting: .shared, attribution: nil)
    }
    defer { gate.release.yield(()) }
    _ = try #require(await started.next())
    try old.edit("# A\n\ntwo\n")
    #expect(await old.next() == .control(.ack(count: 1)))
    await first.stopWorker()
    var next = try await DocumentClient.join(second, plan, peer: "2")
    let before = try await second.currentRevision(in: .shared)
    gate.release.yield(())
    let wrote = try await writing.value
    #expect(wrote == before + 1)
    #expect(try await second.currentRevision(in: .shared) == wrote)
    guard case let .frame(.update(update)) = await next.next() else { Issue.record("no relay on next worker"); return }
    try next.replica.importUpdate(Data(update))
    #expect(next.replica.text == "# B\n\ntwo\n")
    #expect(await next.next() == .control(.checkpoint(rev: Int(wrote))))
    #expect(text(try await second.fs(.shared).read(plan).1) == "# B\n\ntwo\n")
  }
}

private struct MergeGate: Sendable {
  let started: AsyncStream<DocumentPrepared>
  let release: AsyncStream<Void>.Continuation
  let client: DocumentMerge

  init() {
    let (started, starts) = AsyncStream.makeStream(of: DocumentPrepared.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    self.started = started
    self.release = release
    self.client = DocumentMerge { material, path, text, base, checkout, peer, seedPeer in
      let prepared = try await DocumentMerge.live.prepare(material, path, text, base, checkout, peer, seedPeer)
      starts.yield(prepared)
      for await _ in released { break }
      return prepared
    }
  }
}
