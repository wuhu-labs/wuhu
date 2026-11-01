import ControlledTime
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SpaceContract.GroupID
import enum SpaceContract.WmdAccess
import enum SpaceContract.WmdErrorCode
import enum SpaceContract.WmdFrame
import enum SpaceContract.WmdServerControl
@testable import SpaceCore
import SpaceFS
import Synchronization
import Testing
import WmdDocument

@Suite(.deterministicDependencies)
struct WmdNodeTests {
  private let plan = "/notes/plan.wmd"

  @Test func anAgentReadSeesLiveEditsAsCanonicalMarkdown() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("# Plan\n\nHello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    #expect(client.replica.markdown == "# Plan\n\nHello\n")

    try client.edit("# Plan\n\nHello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    let (token, data) = try await space.fs(.shared).read(plan)
    #expect(text(data) == "# Plan\n\nHello there\n")
    #expect(await client.next() == .control(.checkpoint(rev: try #require(token.rev))))
  }

  @Test func anAgentWriteMergesWithEditsMadeSinceItsRead() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("# Plan\n\nOne\n\nTwo\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let (read, _) = try await fs.read(plan)

    try client.edit("# Plan\n\nOne\n\nTwo!\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    let wrote = try await fs.write(plan, bytes("# Plan\n\nOne?\n\nTwo\n"), ifMatch: read)

    let merged = "# Plan\n\nOne?\n\nTwo!\n"
    let (token, data) = try await fs.read(plan)
    #expect(text(data) == merged)
    #expect(token == wrote)
    guard case let .frame(.update(update)) = await client.next() else { Issue.record("no agent update"); return }
    try client.replica.importUpdate(Data(update))
    #expect(client.replica.markdown == merged)
    #expect(await client.next() == .control(.checkpoint(rev: try #require(wrote.rev))))
  }

  @Test func onlyAWriterAskingToCreateOpensAMissingNode() async throws {
    let space = try makeSpace(clock: VirtualClock())
    var reader = await Client.connect(space, "/new.wmd", access: .read, create: true)
    guard case .control(.error(code: .notFound, _)) = await reader.next() else { Issue.record("reader opened a missing node"); return }
    var visitor = await Client.connect(space, "/new.wmd", access: .write)
    guard case .control(.error(code: .notFound, _)) = await visitor.next() else { Issue.record("a visit created the node"); return }
    await #expect(throws: SpaceError.self) { try await space.fs(.shared).read("/new.wmd") }

    var writer = await Client.connect(space, "/new.wmd", access: .write, create: true)
    guard case let .control(.welcome(_, _, _, _, rev)) = await writer.next() else { Issue.record("no welcome"); return }
    let (token, data) = try await space.fs(.shared).read("/new.wmd")
    #expect(rev == token.rev)
    #expect(data.isEmpty)
  }

  @Test func aReadOnlyConnectionMaySyncButNotUpdate() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan, access: .read)
    #expect(client.replica.markdown == "Hello\n")
    try client.edit("Hello there\n")
    guard case .control(.error(code: .readOnly, _)) = await client.next() else { Issue.record("a reader updated"); return }
    #expect(await client.next() == nil)
  }

  @Test func peersSeeEachOtherAndEachOthersEdits() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var ada = try await Client.join(space, plan, peer: "1")
    var bo = try await Client.join(space, plan, peer: "2")
    guard case let .control(.peers(roster)) = await ada.next() else { Issue.record("no roster"); return }
    #expect(roster.map(\.peer) == ["1", "2"])

    bo.send(.presence([7]))
    #expect(await ada.next() == .frame(.presence([7])))
    try bo.edit("Hello, Ada\n")
    #expect(await bo.next() == .control(.ack(count: 1)))
    guard case let .frame(.update(update)) = await ada.next() else { Issue.record("no relay"); return }
    try ada.replica.importUpdate(Data(update))
    #expect(ada.replica.markdown == "Hello, Ada\n")

    bo.leave()
    guard case let .control(.peers(after)) = await ada.next() else { Issue.record("no roster after leaving"); return }
    #expect(after.map(\.peer) == ["1"])
  }

  @Test func loggedEditsSurviveARestart() async throws {
    let database = try DatabaseQueue(path: "file:/wmd-restart-\(UUID())?vfs=memdb")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space(writer: database), Space(writer: database))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    try client.edit("Hello again\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    let (_, data) = try await second.fs(.shared).read(plan)
    #expect(text(data) == "Hello again\n")
  }

  @Test func idleEditingCheckpoints() async throws {
    let clock = VirtualClock()
    let space = try makeSpace(clock: clock)
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello, idle\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await clock.sleeping { $0 == WmdNode.idleCheckpoint }
    await clock.advance(by: WmdNode.idleCheckpoint)
    guard case let .control(.checkpoint(rev)) = await client.next() else { Issue.record("no idle checkpoint"); return }
    let (_, data) = try await space.fs(.shared, at: Rev(rev)).read(plan)
    #expect(text(data) == "Hello, idle\n")
  }

  @Test func anAcknowledgedEditIsLoggedWithoutARevision() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let before = try await space.currentRevision()
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    #expect(try await space.currentRevision() == before)
    #expect(try await space.writer.read { db in try WmdLogRow.all.fetchCount(db) } == 1)
  }

  @Test func aNodeTheServerClosesLastCheckpointsBeforeItRetires() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    let logChanges = regionWakes([GRDB.Table("wmd_log")], in: await space.writer)
    client.sink.yield(.text("not a frame"))
    guard case .control(.error(code: .protocolViolation, _)) = await client.next() else { Issue.record("no refusal"); return }
    #expect(await client.next() == nil)
    for await _ in logChanges where try await space.writer.read({ db in try WmdLogRow.all.fetchCount(db) }) == 0 { break }
    #expect(text(try await space.fs(.shared).read(plan).1) == "Hello there\n")
  }

  @Test func aStopCheckpointsWhatOnlyTheLogHeld() async throws {
    let name = "file:/wmd-stop-\(UUID())?vfs=memdb"
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space(writer: DatabaseQueue(path: name)), Space(writer: DatabaseQueue(path: name)))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    try client.edit("Hello, stop\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await first.close()
    guard case .control(.checkpoint) = await client.next() else { Issue.record("the stop did not checkpoint"); return }
    #expect(try await second.writer.read { db in try WmdLogRow.all.fetchCount(db) } == 0)
    #expect(text(try await second.fs(.shared).read(plan).1) == "Hello, stop\n")
  }

  @Test func aStartCheckpointsWhatAStopLeftInTheLog() async throws {
    let database = try DatabaseQueue(path: "file:/wmd-recover-\(UUID())?vfs=memdb")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space(writer: database), Space(writer: database))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    try client.edit("Hello, again\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    await second.recoverLiveDocuments()
    #expect(try await second.writer.read { db in try WmdLogRow.all.fetchCount(db) } == 0)
    let head = try await second.writer.read { db in try Substrate.head(SpacePath(validating: plan), group: .shared, in: db) }
    #expect(try await space(second, blobOf: try #require(head)) == "Hello, again\n")
  }

  private func space(_ space: Space, blobOf head: FSHeadRow) async throws -> String {
    let hash = try #require(head.blobHash)
    return text(Data(try await space.blobs.read(space.writer) { db, cache in try cache.blob(of: hash, in: db).content }))
  }

  @Test func aCheckoutMergesIntoTheLiveDocument() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let first = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Two\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    let (second, _) = try await fs.read(plan)
    #expect(await client.next() == .control(.checkpoint(rev: try #require(second.rev))))

    let (_, restored) = try await space.checkout(SpacePath(validating: plan), rev: Rev(try #require(first.rev)), in: .shared, acting: .shared)
    guard case let .frame(.update(update)) = await client.next() else { Issue.record("no merged checkout"); return }
    try client.replica.importUpdate(Data(update))
    #expect(client.replica.markdown == "One\n")
    #expect(await client.next() == .control(.checkpoint(rev: try #require(restored.rev))))
    #expect(text(try await fs.read(plan).1) == "One\n")
  }

  @Test func aDeleteClosesTheNodeAndAReconnectIsRefused() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await fs.delete(plan, ifMatch: nil)
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the node outlived its file"); return }
    #expect(await client.next() == nil)
    var reconnect = await Client.connect(space, plan, peer: "2")
    guard case .control(.error(code: .notFound, _)) = await reconnect.next() else { Issue.record("a reconnect resurrected the node"); return }
    await #expect(throws: SpaceError.self) { try await fs.read(plan) }
    let again = try await Client.join(space, plan, peer: "3", create: true)
    #expect(again.replica.markdown == "")
    #expect(text(try await fs.read(plan).1) == "")
  }

  @Test func aMoveCarriesTheHistoryAlong() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let moved = "/notes/moved.wmd"
    _ = try await fs.write(plan, bytes("One\n\nTwo\n"), ifMatch: nil)
    let (read, _) = try await fs.read(plan)
    var client = try await Client.join(space, plan)
    try client.edit("One\n\nTwo!\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await fs.move(plan, to: moved)
    guard case .control(.checkpoint) = await client.next() else { Issue.record("the move did not settle the node"); return }
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the node stayed at the old path"); return }
    _ = try await fs.write(moved, bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await fs.read(moved).1) == "One?\n\nTwo!\n")
  }

  @Test func aMoveFromAnotherGroupReplacesALiveNode() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let team = try await space.createGroup(alias: "team", owner: owner.id)
    _ = try await space.fs(team).write("/theirs.wmd", bytes("Theirs\n"), ifMatch: nil)
    _ = try await space.fs(.shared).write(plan, bytes("Ours\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)

    try await space.move("/theirs.wmd", in: team, to: plan, in: .shared, replacing: true, acting: .shared)
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the replaced node lived on"); return }
    var again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.markdown == "Theirs\n")
    try again.edit("Theirs, edited\n")
    #expect(await again.next() == .control(.ack(count: 1)))
    #expect(text(try await space.fs(.shared).read(plan).1) == "Theirs, edited\n")
  }

  @Test func syntaxTheNodeCannotHoldIsRefusedWithItsLine() async throws {
    let space = try makeSpace(clock: VirtualClock())
    do {
      _ = try await space.fs(.shared).write(plan, bytes("Hello\n\n<div>\n"), ifMatch: nil)
      Issue.record("HTML was accepted")
    } catch let SpaceError.wmdSyntax(path, line, _) {
      #expect(path == plan && line == 3)
    }
  }

  @Test func aFileThatIsNoDocumentIsRefusedLiveAndReplacedByAWrite() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let stale = try await fs.write("/raw.md", bytes("Hello\n\n<div>\n"), ifMatch: nil)
    try await fs.move("/raw.md", to: plan)
    var client = await Client.connect(space, plan)
    guard case .control(.error(code: .notWmd, _)) = await client.next() else { Issue.record("a foreign file opened live"); return }
    let (raw, data) = try await fs.read(plan)
    #expect(text(data) == "Hello\n\n<div>\n")

    await #expect(throws: SpaceError.versionMismatch(plan)) { _ = try await fs.write(plan, bytes("Fresh\n"), ifMatch: stale) }
    _ = try await fs.write(plan, bytes("Fresh\n"), ifMatch: raw)
    #expect(text(try await fs.read(plan).1) == "Fresh\n")
    let again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.markdown == "Fresh\n")
  }

  @Test func aWriteMergesOnlyAtARevisionACheckpointWrote() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    let unrelated = try await fs.write("/other.md", bytes("Other\n"), ifMatch: nil)
    await #expect(throws: SpaceError.versionMismatch(plan)) { _ = try await fs.write(plan, bytes("Two\n"), ifMatch: unrelated) }
  }

  @Test func aConnectionClosesWhenItsPrincipalLosesAccess() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    let access = Mutex<WmdAccess?>(.write)
    let reauthorize: @Sendable () async -> WmdAccess? = { access.withLock { $0 } }
    var writer = try await Client.join(space, plan, peer: "1", reauthorize: reauthorize)
    var reader = try await Client.join(space, plan, access: .read, peer: "2", reauthorize: reauthorize)
    guard case .control(.peers) = await writer.next() else { Issue.record("no roster"); return }

    access.withLock { $0 = .read }
    _ = try await space.createGroup(alias: "team", owner: owner.id)
    guard case .control(.error(code: .readOnly, _)) = await writer.next() else { Issue.record("a downgraded writer stayed"); return }
    #expect(await writer.next() == nil)
    guard case .control(.peers) = await reader.next() else { Issue.record("no roster after the downgrade"); return }

    access.withLock { $0 = nil }
    _ = try await space.createGroup(alias: "crew", owner: owner.id)
    guard case .control(.error(code: .forbidden, _)) = await reader.next() else { Issue.record("a reader without access stayed"); return }
  }

  @Test func theSpacesOwnFoldersAreNotOpenedLive() async throws {
    let space = try makeSpace(clock: VirtualClock())
    var client = await Client.connect(space, "/_/notes.wmd", create: true)
    guard case .control(.error(code: .forbidden, _)) = await client.next() else { Issue.record("a reserved path opened"); return }
  }

  @Test func anUpdateBeforeSyncedIsAProtocolViolation() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = await Client.connect(space, plan)
    guard case .control(.welcome) = await client.next() else { Issue.record("no welcome"); return }
    try client.edit("Hello there\n")
    guard case .control(.error(code: .protocolViolation, _)) = await client.next() else { Issue.record("an early update was taken"); return }
  }

  @Test func anUpdateMissingItsDependenciesIsRefused() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let unsent = try #require(try client.replica.merge(markdown: "Hello there\n", base: nil, peer: 900))
    try client.replica.importUpdate(unsent)
    client.send(.update(Array(try #require(try client.replica.merge(markdown: "Hello there, you\n", base: nil, peer: 901)))))
    guard case .control(.error(code: .missingDependencies, _)) = await client.next() else { Issue.record("a dangling update was taken"); return }
  }

  @Test func deletingOrMovingAFolderClosesTheNodesInIt() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n\nTwo\n"), ifMatch: nil)
    let (read, _) = try await fs.read(plan)
    var moving = try await Client.join(space, plan)
    try moving.edit("One\n\nTwo!\n")
    #expect(await moving.next() == .control(.ack(count: 1)))

    try await fs.move("/notes", to: "/archive")
    guard case .control(.checkpoint) = await moving.next() else { Issue.record("the move did not settle the node"); return }
    guard case .control(.error(code: .notFound, _)) = await moving.next() else { Issue.record("the node stayed in the old folder"); return }
    _ = try await fs.write("/archive/plan.wmd", bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await fs.read("/archive/plan.wmd").1) == "One?\n\nTwo!\n")

    var deleting = try await Client.join(space, "/archive/plan.wmd", peer: "2")
    try await fs.delete("/archive", ifMatch: nil)
    guard case .control(.error(code: .notFound, _)) = await deleting.next() else { Issue.record("the node outlived its folder"); return }
  }

  @Test func aMachineMoveCarriesItsLiveNotesAlong() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let alice = GroupID(rawValue: "alice")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('alice', '2026-01-01T00:00:00.000Z')")
    }
    let machine = try await space.addMachine(name: "studio", group: alice)
    let notes = "/_/machines/studio/notes.wmd"
    let hers = await space.fs(alice)
    _ = try await hers.write(notes, bytes("One\n\nTwo\n"), ifMatch: nil)
    let (read, _) = try await hers.read(notes)
    var client = try await Client.join(space, notes, group: alice)
    try client.edit("One\n\nTwo!\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    _ = try await space.moveMachine(machine.id, to: .shared)
    guard case .control(.checkpoint) = await client.next() else { Issue.record("the move did not settle the node"); return }
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the node stayed in the old group"); return }
    let shared = await space.fs(.shared)
    _ = try await shared.write(notes, bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await shared.read(notes).1) == "One?\n\nTwo!\n")
  }
}

/// A client of one node, holding its own replica.
private struct Client {
  let replica: WmdReplica
  let sink: AsyncStream<WmdInbound>.Continuation
  var outbound: AsyncStream<WmdOutbound>.AsyncIterator
  var nextPeer: UInt64

  static func connect(
    _ space: Space, _ path: String, group: GroupID = .shared, access: WmdAccess = .write, peer: String = "1", create: Bool = false,
    reauthorize: @escaping @Sendable () async -> WmdAccess? = { .write },
  ) async -> Client {
    let (frames, sink) = AsyncStream.makeStream(of: WmdInbound.self)
    let outbound = await space.wmdChannel(
      group, try! SpacePath(validating: path), peer: peer, name: "peer " + peer, access: access, create: create, frames: frames,
      reauthorize: reauthorize,
    )
    return Client(replica: WmdReplica(), sink: sink, outbound: outbound.makeAsyncIterator(), nextPeer: UInt64(peer)! << 32)
  }

  /// Through welcome, the catch-up and synced.
  static func join(
    _ space: Space, _ path: String, group: GroupID = .shared, access: WmdAccess = .write, peer: String = "1", create: Bool = false,
    reauthorize: @escaping @Sendable () async -> WmdAccess? = { .write },
  ) async throws -> Client {
    var client = await connect(space, path, group: group, access: access, peer: peer, create: create, reauthorize: reauthorize)
    guard case .control(.welcome) = await client.next() else { throw Unexpected() }
    client.send(.sync(versionVector: Array(client.replica.versionVector)))
    var next = await client.next()
    if case let .frame(.update(update)) = next {
      try client.replica.importUpdate(Data(update))
      next = await client.next()
    }
    guard case .frame(.synced) = next else { throw Unexpected() }
    return client
  }

  mutating func next() async -> WmdOutbound? { await outbound.next() }

  func send(_ frame: WmdFrame) { sink.yield(.binary(frame.bytes)) }

  mutating func edit(_ markdown: String) throws {
    nextPeer += 1
    let update = try #require(try replica.merge(markdown: markdown, base: nil, peer: nextPeer))
    try replica.importUpdate(update)
    send(.update(Array(update)))
  }

  func leave() { sink.finish() }

  struct Unexpected: Error {}
}
