import CanvasDocument
import ControlledTime
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import KeelObjectStore
import LiveDocument
import Scratch
import struct SpaceContract.GroupID
import enum SpaceContract.LiveAccess
import enum SpaceContract.LiveErrorCode
import enum SpaceContract.LiveFrame
import enum SpaceContract.LiveServerControl
@testable import SpaceCore
import SpaceFS
import StructuredQueries
import Synchronization
import Testing
import WmdDocument
import Wuwei
import WuweiQueries

private typealias Client = DocumentClient

@Suite(.deterministicDependencies)
struct DocumentCellTests {
  private let plan = "/notes/plan.wmd"

  /// The space's worker reads the injected clock where it is made, and the documents' idle wake is the
  /// worker's timer: make it inside the clock's scope.
  private func space(clock: VirtualClock) throws -> Space {
    try withDependencies {
      $0.date = .constant(fixedDate)
      $0.continuousClock = clock
    } operation: {
      let space = try Space.inMemory()
      _ = space.worker
      return space
    }
  }

  private let idleCheckpoint = Duration.milliseconds(DocumentCell.idleCheckpoint)

  private func fireIdleCheckpoint(_ clock: VirtualClock) async throws {
    try await clock.sleeping { $0 == idleCheckpoint }
    await clock.advance(by: idleCheckpoint)
  }

  @Test func anAgentReadSeesLiveEditsAsCanonicalMarkdown() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("# Plan\n\nHello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    #expect(client.replica.text == "# Plan\n\nHello\n")

    try client.edit("# Plan\n\nHello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    let (token, data) = try await space.fs(.shared).read(plan)
    #expect(text(data) == "# Plan\n\nHello there\n")
    #expect(await client.next() == .control(.checkpoint(rev: try #require(token.rev))))
  }

  @Test func aCanvasIsALiveDocumentWhoseAgentWritesMergeByID() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let board = "/boards/plan.canvas"
    let fs = await space.fs(.shared)
    _ = try await fs.write(board, bytes("- sticky {@0,0} Ship\n"), ifMatch: nil)
    var client = try await Client.join(space, board)
    let (read, data) = try await fs.read(board)
    #expect(text(data).hasPrefix("- sticky {#"))
    #expect(client.replica.text == text(data))

    try client.edit(text(data).replacing("@0,0", with: "@300,200"))
    #expect(await client.next() == .control(.ack(count: 1)))
    _ = try await fs.write(board, bytes(text(data).replacing("Ship", with: "Ship **v1**")), ifMatch: read)
    #expect(text(try await fs.read(board).1).contains("@300,200 220x220 blue} Ship **v1**\n"))
    await #expect(throws: SpaceError.liveSyntax(path: board, line: 1, reason: "#zzzzzz is not on this board; omit the id to create a new item or connector")) {
      try await fs.write(board, bytes("- sticky {#zzzzzz} x\n"), ifMatch: nil)
    }
    let copy = "/boards/copy.canvas"
    let copied = text(try await fs.read(board).1)
    _ = try await fs.write(copy, bytes(copied), ifMatch: nil)
    #expect(text(try await fs.read(copy).1) == copied, "a write that creates a board keeps the ids it names")
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
    #expect(client.replica.text == merged)
    #expect(await client.next() == .control(.checkpoint(rev: try #require(wrote.rev))))
  }

  @Test func onlyAWriterAskingToCreateOpensAMissingDocument() async throws {
    let space = try makeSpace(clock: VirtualClock())
    var reader = await Client.connect(space, "/new.wmd", access: .read, create: true)
    guard case .control(.error(code: .notFound, _)) = await reader.next() else { Issue.record("a reader opened a missing document"); return }
    var visitor = await Client.connect(space, "/new.wmd", access: .write)
    guard case .control(.error(code: .notFound, _)) = await visitor.next() else { Issue.record("a visit created the document"); return }
    await #expect(throws: SpaceError.self) { try await space.fs(.shared).read("/new.wmd") }

    var writer = await Client.connect(space, "/new.wmd", access: .write, create: true)
    guard case let .control(.welcome(_, _, _, _, rev)) = await writer.next() else { Issue.record("no welcome"); return }
    let (token, data) = try await space.fs(.shared).read("/new.wmd")
    #expect(rev == nil)
    #expect(await writer.nextNonRoster() == .control(.checkpoint(rev: try #require(token.rev))))
    #expect(data.isEmpty)
  }

  @Test func aReadOnlyConnectionMaySyncButNotUpdate() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan, access: .read)
    #expect(client.replica.text == "Hello\n")
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
    #expect(ada.replica.text == "Hello, Ada\n")

    bo.leave()
    guard case let .control(.peers(after)) = await ada.next() else { Issue.record("no roster after leaving"); return }
    #expect(after.map(\.peer) == ["1"])
  }

  @Test func anUpdateBeforeItsSyncLandsAndTheSyncStillCatchesUp() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var early = await Client.connect(space, plan, peer: "1")
    guard case .control(.welcome) = await early.next() else { Issue.record("no welcome"); return }
    var later = try await Client.join(space, plan, peer: "2")
    guard case .control(.peers) = await early.next() else { Issue.record("no roster"); return }

    // A frame a client sends before its sync is taken, logged and relayed; its sync then still catches up.
    try later.edit("Hello, early\n")
    #expect(await later.next() == .control(.ack(count: 1)))
    guard case let .frame(.update(update)) = await early.next() else { Issue.record("a gate held the frame back"); return }
    #expect(throws: LiveError.missingDependencies) { try early.replica.importUpdate(Data(update)) }
    #expect(early.replica.text == "")

    early.send(.sync(versionVector: Array(early.replica.versionVector)))
    guard case let .frame(.update(catchUp)) = await early.next() else { Issue.record("no catch-up"); return }
    try early.replica.importUpdate(Data(catchUp))
    #expect(early.replica.text == "Hello, early\n", "the frame that waited applied with the catch-up")
    guard case .frame(.synced) = await early.next() else { Issue.record("no synced"); return }
    #expect(text(try await space.fs(.shared).read(plan).1) == "Hello, early\n")
  }

  @Test func loggedEditsSurviveARestart() async throws {
    let folder = try ScratchFolder("document-restart")
    let file = folder.url.appending(path: "space.sqlite")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space.open(file: file), Space.open(file: file))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    try client.edit("Hello again\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    await first.stopWorker()
    let (_, data) = try await second.fs(.shared).read(plan)
    #expect(text(data) == "Hello again\n")
  }

  @Test func idleEditingCheckpoints() async throws {
    let clock = VirtualClock()
    let space = try space(clock: clock)
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello, idle\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    let due = space.worker.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan))).nextWake()
    #expect(due != nil, "the frame left no wake")

    try await fireIdleCheckpoint(clock)
    let frame = await client.next()
    guard case let .control(.checkpoint(rev))? = frame else { Issue.record("no idle checkpoint: \(String(describing: frame))"); return }
    let (_, data) = try await space.fs(.shared, at: Rev(rev)).read(plan)
    #expect(text(data) == "Hello, idle\n")
  }

  @Test func aCheckpointKeepsTheMergeBasesAnAgentRead() async throws {
    let clock = VirtualClock()
    let space = try space(clock: clock)
    let fs = await space.fs(.shared)
    let read = try await fs.write(plan, bytes("# A\n\none\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("# A\n\ntwo\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    try await fireIdleCheckpoint(clock)
    guard case .control(.checkpoint)? = await client.next() else { Issue.record("no idle checkpoint"); return }

    // The agent writes at the revision it read, which the idle checkpoint has since overtaken.
    _ = try await fs.write(plan, bytes("# B\n\none\n"), ifMatch: read)
    #expect(text(try await fs.read(plan).1) == "# B\n\ntwo\n")

    // A base two checkpoints old still merges.
    let (second, _) = try await fs.read(plan)
    var other = try await Client.join(space, plan, peer: "2")
    try other.edit("# B\n\nfour\n")
    #expect(await other.next() == .control(.ack(count: 1)))
    try await fireIdleCheckpoint(clock)
    guard case .control(.checkpoint)? = await other.next() else { Issue.record("no second idle checkpoint"); return }
    _ = try await fs.write(plan, bytes("# C\n\ntwo\n"), ifMatch: second)
    #expect(text(try await fs.read(plan).1) == "# C\n\nfour\n")
  }

  @Test func anUnchangedTextCommitsAtTheRevisionItAlreadyHas() async throws {
    let clock = VirtualClock()
    let space = try space(clock: clock)
    let fs = await space.fs(.shared)
    let read = try await fs.write(plan, bytes("# A\n\none\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let before = try await space.currentRevision(in: .shared)
    let revision = try #require(read.rev)
    let original = space.worker.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan))).checkpoints().first { $0.rev == revision }?.frontiers

    // Two changed frames that cancel out: the text is the file's again, and the log is not empty.
    try client.edit("# A\n\none!\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    try client.edit("# A\n\none\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    try await fireIdleCheckpoint(clock)
    guard case let .control(.checkpoint(rev))? = await client.next() else { Issue.record("no idle checkpoint"); return }
    #expect(rev == read.rev, "an unchanged text minted a revision")
    #expect(try await space.currentRevision(in: .shared) == before)

    try space.worker.read { reader in
      let document = reader.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan)))
      let kept = document.checkpoints().filter { $0.rev == revision }
      let state = try #require(document.state())
      #expect(kept.count == 1, "the revision kept \(kept.count) checkpoint rows")
      #expect(state.dirtyAt == nil, "an unchanged commit stayed due")
      #expect(kept.first?.frontiers == original, "an existing revision's mapping is immutable")
    }

    _ = try await fs.write(plan, bytes("# B\n\none\n"), ifMatch: read)
    #expect(text(try await fs.read(plan).1) == "# B\n\none\n")
  }

  @Test func anAcknowledgedEditIsLoggedWithoutARevision() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let before = try await space.currentRevision(in: .shared)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    #expect(try await space.currentRevision(in: .shared) == before)
    #expect(try logRows(space) == 1)
  }

  @Test func aRefusedFrameClosesOnlyItsSocketAndTheNextReadCommitsTheLog() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    var observer = try await Client.join(space, plan, peer: "2")
    guard case .control(.peers) = await client.next() else { Issue.record("no roster"); return }
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    guard case .frame(.update) = await observer.next() else { Issue.record("no relay"); return }

    client.sink.yield(.text("not a frame"))
    guard case .control(.error(code: .protocolViolation, _)) = await client.next() else { Issue.record("no refusal"); return }
    #expect(await client.next() == nil)
    guard case let .control(.peers(after)) = await observer.next() else { Issue.record("the refused socket took the other one with it"); return }
    #expect(after.map(\.peer) == ["2"], "roster \(after.map(\.peer))")
    #expect(try logRows(space) == 1)
    #expect(text(try await space.fs(.shared).read(plan).1) == "Hello there\n")
    #expect(try logRows(space) == 0)
  }

  @Test func aStopLeavesTheEditsInTheLogAndTheNextReaderCommitsThem() async throws {
    let folder = try ScratchFolder("document-stop")
    let file = folder.url.appending(path: "space.sqlite")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space.open(file: file), Space.open(file: file))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    try client.edit("Hello, stop\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await first.close()
    #expect(try logRows(second) == 1, "a stop writes no file")
    #expect(text(try await second.fs(.shared).read(plan).1) == "Hello, stop\n")
    #expect(try logRows(second) == 0)
  }

  private func logRows(_ space: Space) throws -> Int {
    try space.worker.cell(DocumentCell.ID(.shared, SpacePath(validating: plan))).pendingUpdates()
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
    #expect(client.replica.text == "One\n")
    #expect(await client.next() == .control(.checkpoint(rev: try #require(restored.rev))))
    #expect(text(try await fs.read(plan).1) == "One\n")
  }

  @Test func aDeleteClosesTheDocumentAndAReconnectIsRefused() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await fs.delete(plan, ifMatch: nil)
    guard case .control(.checkpoint) = await client.next() else { Issue.record("the delete did not checkpoint the document"); return }
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the document outlived its file"); return }
    #expect(await client.next() == nil)
    var reconnect = await Client.connect(space, plan, peer: "2")
    guard case .control(.error(code: .notFound, _)) = await reconnect.next() else { Issue.record("a reconnect resurrected the document"); return }
    await #expect(throws: SpaceError.self) { try await fs.read(plan) }
    let again = try await Client.join(space, plan, peer: "3", create: true)
    #expect(again.replica.text == "")
    #expect(text(try await fs.read(plan).1) == "")
  }

  @Test func aMoveEndsTheHistoryAtTheOldPath() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let moved = "/notes/moved.wmd"
    _ = try await fs.write(plan, bytes("One\n\nTwo\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("One\n\nTwo!\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await fs.move(plan, to: moved)
    guard case .control(.checkpoint) = await client.next() else { Issue.record("the move did not settle the document"); return }
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the document stayed at the old path"); return }

    let (read, data) = try await fs.read(moved)
    #expect(text(data) == "One\n\nTwo!\n")
    _ = try await fs.write(moved, bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await fs.read(moved).1) == "One?\n\nTwo\n", "the moved document is the file's text, not the old history")
  }

  @Test func aMoveUnderEditingCarriesItsCheckpointAndDropsLaterFrames() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let moved = "/archive/plan.wmd"
    _ = try await fs.write(plan, bytes("Start\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    var acknowledged = "Start\n"
    let moving = Task { try await fs.move("/notes", to: "/archive") }
    for line in 1 ... 8 {
      try client.edit(acknowledged + "line \(line)\n")
      guard case .control(.ack)? = await client.next() else { break }
      acknowledged += "line \(line)\n"
    }
    try await moving.value
    let carried = text(try await fs.read(moved).1)
    #expect(carried.hasPrefix("Start\n"))
    #expect(acknowledged.hasPrefix(carried))
  }

  @Test func aPathThroughAFileIsRefusedTypedForBothWriters() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write("/parent.txt", bytes("not a folder\n"), ifMatch: nil)
    await #expect(throws: SpaceError.notADirectory("/parent.txt")) {
      _ = try await fs.write("/parent.txt/doc.wmd", bytes("One\n"), ifMatch: nil)
    }
    var client = await Client.connect(space, "/parent.txt/doc.wmd", create: true)
    guard case .control(.error(code: .notFound, _)) = await client.next() else {
      Issue.record("a document was created through a file")
      return
    }
    #expect(await client.next() == nil)
    let document = space.worker.cell(DocumentCell.ID(.shared, try SpacePath(validating: "/parent.txt/doc.wmd")))
    #expect(document.state() == nil)
  }

  @Test func aStaleHistoryOverAnExternalFileIsReplacedFromTheStore() async throws {
    let folder = try ScratchFolder("document-external")
    let space = try Space.inMemory(objects: FileSystemObjectStore(root: folder.url.appendingPathComponent("objects")))
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("One, typed\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    // A file too big to be inline is moved onto the path, and the mail never comes.
    let big = String(repeating: "x", count: Bucket.inlineThreshold + 1) + "\n"
    let blob = try await space.bucket.stage(Array(big.utf8))
    _ = try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.write(SpacePath(validating: plan), blob: blob, ifMatch: nil, createOnly: false, mtime: SQLiteDateFormat.string(from: fixedDate), attribution: nil)
    }
    let bucketBlob = try await space.bucket.blob(Substrate.blobHash(Array(big.utf8)))
    guard bucketBlob.externalKey != nil else { Issue.record("the file stayed inline, so nothing is fetched"); return }
    try space.worker.read { reader in
      let document = reader.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan)))
      let stored = document.fileRev()
      let head = try #require(reader.cell(FilesCell.ID(GroupID.shared.rawValue)).file(SpacePath(validating: plan))).rev
      #expect(stored != head, "the rows still stand for the replaced file")
    }

    let again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.text == big)
    #expect(text(try await fs.read(plan).1) == big)
  }

  @Test func aMoveFromAnotherGroupReplacesALiveDocument() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let team = try await space.createGroup(alias: "team", owner: owner.id)
    _ = try await space.fs(team).write("/theirs.wmd", bytes("Theirs\n"), ifMatch: nil)
    _ = try await space.fs(.shared).write(plan, bytes("Ours\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)

    try await space.move("/theirs.wmd", in: team, to: plan, in: .shared, replacing: true, acting: .shared)
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the replaced document lived on"); return }
    var again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.text == "Theirs\n")
    try again.edit("Theirs, edited\n")
    #expect(await again.next() == .control(.ack(count: 1)))
    #expect(text(try await space.fs(.shared).read(plan).1) == "Theirs, edited\n")
  }

  @Test func syntaxTheDocumentCannotHoldIsRefusedWithItsLine() async throws {
    let space = try makeSpace(clock: VirtualClock())
    do {
      _ = try await space.fs(.shared).write(plan, bytes("Hello\n\n<div>\n"), ifMatch: nil)
      Issue.record("HTML was accepted")
    } catch let SpaceError.liveSyntax(path, line, _) {
      #expect(path == plan && line == 3)
    }
  }

  @Test func aFileThatIsNoDocumentIsRefusedLiveAndReplacedByAWrite() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let stale = try await fs.write("/raw.md", bytes("Hello\n\n<div>\n"), ifMatch: nil)
    try await fs.move("/raw.md", to: plan)
    var client = await Client.connect(space, plan)
    guard case .control(.error(code: .notLive, _)) = await client.next() else { Issue.record("a foreign file opened live"); return }
    let (raw, data) = try await fs.read(plan)
    #expect(text(data) == "Hello\n\n<div>\n")

    await #expect(throws: SpaceError.versionMismatch(plan)) { _ = try await fs.write(plan, bytes("Fresh\n"), ifMatch: stale) }
    _ = try await fs.write(plan, bytes("Fresh\n"), ifMatch: raw)
    #expect(text(try await fs.read(plan).1) == "Fresh\n")
    let again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.text == "Fresh\n")
  }

  @Test func aWriteMergesOnlyAtARevisionACheckpointWrote() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n"), ifMatch: nil)
    let unrelated = try await fs.write("/other.md", bytes("Other\n"), ifMatch: nil)
    await #expect(throws: SpaceError.versionMismatch(plan)) { _ = try await fs.write(plan, bytes("Two\n"), ifMatch: unrelated) }
  }

  @Test func aPeerWhoseAccessWeakensLosesItsSocket() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    let access = Mutex<LiveAccess?>(.write)
    let reauthorize: @Sendable () async -> LiveAccess? = { access.withLock { $0 } }
    var writer = try await Client.join(space, plan, peer: "1", reauthorize: reauthorize)
    var reader = try await Client.join(space, plan, access: .read, peer: "2", reauthorize: reauthorize)
    guard case .control(.peers) = await writer.next() else { Issue.record("no roster"); return }

    access.withLock { $0 = .read }
    _ = try await space.createGroup(alias: "team", owner: owner.id)
    guard case .control(.error(code: .readOnly, _))? = await writer.next() else { Issue.record("a downgraded writer was not told why"); return }
    #expect(await writer.next() == nil, "a downgraded writer kept its socket")
    guard case .control(.peers) = await reader.next() else { Issue.record("no roster after the downgrade"); return }

    access.withLock { $0 = nil }
    _ = try await space.createGroup(alias: "crew", owner: owner.id)
    guard case .control(.error(code: .forbidden, _))? = await reader.next() else { Issue.record("a reader without access was not told why"); return }
    #expect(await reader.next() == nil, "a reader without access kept its socket")
  }

  @Test func theSpacesOwnFoldersAreNotOpenedLive() async throws {
    let space = try makeSpace(clock: VirtualClock())
    var client = await Client.connect(space, "/_/notes.wmd", create: true)
    guard case .control(.error(code: .forbidden, _)) = await client.next() else { Issue.record("a reserved path opened"); return }
  }

  @Test func anUpdateMissingItsDependenciesIsRefused() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let unsent = try #require(try client.replica.merge(text: "Hello there\n", base: nil, peer: 900)?.update)
    try client.replica.importUpdate(unsent)
    client.send(.update(Array(try #require(try client.replica.merge(text: "Hello there, you\n", base: nil, peer: 901)?.update))))
    guard case .control(.error(code: .missingDependencies, _)) = await client.next() else { Issue.record("a dangling update was taken"); return }
  }

  @Test func deletingOrMovingAFolderClosesTheDocumentsInIt() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("One\n\nTwo\n"), ifMatch: nil)
    var moving = try await Client.join(space, plan)
    try moving.edit("One\n\nTwo!\n")
    #expect(await moving.next() == .control(.ack(count: 1)))

    try await fs.move("/notes", to: "/archive")
    let settled = await moving.next()
    guard case .control(.checkpoint)? = settled else { Issue.record("the move did not settle the document: \(String(describing: settled))"); return }
    guard case .control(.error(code: .notFound, _)) = await moving.next() else { Issue.record("the document stayed in the old folder"); return }
    let (read, data) = try await fs.read("/archive/plan.wmd")
    #expect(text(data) == "One\n\nTwo!\n")
    _ = try await fs.write("/archive/plan.wmd", bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await fs.read("/archive/plan.wmd").1) == "One?\n\nTwo\n")

    var deleting = try await Client.join(space, "/archive/plan.wmd", peer: "2")
    try await fs.delete("/archive", ifMatch: nil)
    guard case .control(.error(code: .notFound, _)) = await deleting.next() else { Issue.record("the document outlived its folder"); return }
  }

  @Test func aMachineMoveCarriesItsLiveNotesAlong() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let alice = try await space.createGroup(alias: "alice", owner: owner.id)
    let machine = try await space.addMachineV2(name: "studio", group: alice).machine
    let notes = "/_/machines/studio/notes.wmd"
    let hers = await space.fs(alice)
    _ = try await hers.write(notes, bytes("One\n\nTwo\n"), ifMatch: nil)
    var client = try await Client.join(space, notes, group: alice)
    try client.edit("One\n\nTwo!\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    _ = try await space.moveMachine(machine.id, to: .shared)
    let settled = await client.next()
    guard case .control(.checkpoint)? = settled else { Issue.record("the move did not settle the document: \(String(describing: settled))"); return }
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the document stayed in the old group"); return }
    while space.worker.hasMail(for: FilesCell.ID(alice.rawValue).recipient) || space.worker.hasMail(for: FilesCell.ID(GroupID.shared.rawValue).recipient) { await Task.yield() }
    let shared = await space.fs(.shared)
    let (read, data) = try await shared.read(notes)
    #expect(text(data) == "One\n\nTwo!\n")
    _ = try await shared.write(notes, bytes("One?\n\nTwo\n"), ifMatch: read)
    #expect(text(try await shared.read(notes).1) == "One?\n\nTwo\n")
  }

  @Test func aFoldKeepsTheTextAndTheCheckpointsBase() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let first = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    let before = try await space.currentRevision(in: .shared)

    var typed = "Hello\n"
    for line in 0 ..< DocumentCell.foldLength {
      typed += "line \(line)\n"
      try client.edit(typed)
      #expect(await client.next() == .control(.ack(count: 1)))
    }
    #expect(try logRows(space) == 0, "the log folded into the snapshot")
    #expect(try await space.currentRevision(in: .shared) == before, "a fold writes no file")

    let (read, data) = try await fs.read(plan)
    #expect(text(data) == typed)
    #expect(text(try await space.fs(.shared, at: Rev(try #require(first.rev))).read(plan).1) == "Hello\n")
    _ = try await fs.write(plan, bytes(typed.replacing("Hello", with: "Hello!")), ifMatch: read)
    #expect(text(try await fs.read(plan).1) == typed.replacing("Hello", with: "Hello!"))
  }

  @Test func aFileReplacedBehindTheDocumentStartsItOver() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    // A writer that never tells the cell replaces the file at a revision of its own.
    let replaced = Array("Other\n".utf8)
    let blob = Blob(hash: Substrate.blobHash(replaced), content: replaced, externalKey: nil)
    _ = try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.write(SpacePath(validating: plan), blob: blob, ifMatch: nil, createOnly: false, mtime: SQLiteDateFormat.string(from: fixedDate), attribution: nil)
    }

    let again = try await Client.join(space, plan, peer: "2")
    #expect(again.replica.text == "Other\n")
    guard case .control(.error(code: .notFound, _)) = await client.next() else { Issue.record("the old document kept its socket"); return }
    // The new history starts from the file's text: nothing of the old one is left in any of the four rows.
    try space.worker.read { reader in
      let document = reader.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan)))
      let state = try #require(document.state())
      let fileRev = state.fileRev ?? -1
      let head = try reader.cell(FilesCell.ID(GroupID.shared.rawValue)).file(SpacePath(validating: plan))?.rev ?? -1
      let log = document.pendingUpdates()
      let checkpoints = document.checkpoints().count
      let snapshots = document.snapshotCount()
      #expect(fileRev == head, "the state stands at another revision than the file")
      #expect(
        log == 0 && checkpoints == 1 && snapshots == 1,
        "rows of the old history outlived it: log \(log), checkpoints \(checkpoints), snapshots \(snapshots)",
      )
    }
  }

  @Test func aRolloverKeepsTheAcknowledgedEditExactlyOnce() async throws {
    let folder = try ScratchFolder("document-rollover")
    let file = folder.url.appending(path: "space.sqlite")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      try (Space.open(file: file), Space.open(file: file))
    }
    _ = try await first.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(first, plan)
    let update = try #require(try client.replica.merge(text: "Hello, rolled\n", base: nil, peer: 77)?.update)
    try client.replica.importUpdate(update)
    client.send(.update(Array(update)))
    #expect(await client.next() == .control(.ack(count: 1)))
    #expect(try logRows(first) == 1)

    await first.stopWorker()
    #expect(await client.next() == nil, "the drained worker kept the socket")

    // The client reconnects to the worker that took the document over and, never having seen its ack
    // again, sends the same update: the document holds it once.
    var again = try await Client.join(second, plan, peer: "1")
    again.send(.update(Array(update)))
    #expect(await again.next() == .control(.ack(count: 1)))
    #expect(try logRows(second) == 1)
    #expect(text(try await second.fs(.shared).read(plan).1) == "Hello, rolled\n")
  }

  @Test func removalMailOutlivesTheRemovingWorkerWithoutDelivery() async throws {
    let folder = try ScratchFolder("document-removal-rollover")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let (first, second) = try withDependencies { $0.continuousClock = VirtualClock() } operation: {
      let spaces = try (Space.open(file: file), Space.open(file: file))
      _ = spaces.0.worker; _ = spaces.1.worker
      return spaces
    }
    let content = Array("Hello\n".utf8)
    let blob = Blob(hash: Substrate.blobHash(content), content: content, externalKey: nil)
    _ = try await second.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.write(SpacePath(validating: plan), blob: blob, ifMatch: nil, createOnly: true, mtime: SQLiteDateFormat.string(from: fixedDate), attribution: nil)
    }
    var client = try await Client.join(first, plan)
    try client.edit("Hello, durable\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    let id = DocumentCell.ID(.shared, try SpacePath(validating: plan))
    second.worker.start()
    try await second.fs(.shared).delete("/notes", ifMatch: nil)
    #expect(try second.worker.cell(FilesCell.ID(GroupID.shared.rawValue)).file(SpacePath(validating: plan)) == nil)
    second.worker.read { reader in
      let held = reader.cell(id)
      #expect(held.state() != nil)
      #expect(held.snapshotCount() == 1)
      #expect(!held.checkpoints().isEmpty)
    }
    #expect(second.worker.hasMail(for: id.recipient))
    try await first.close()
    second.worker.poke(id.recipient)
    while second.worker.hasMail(for: id.recipient) { await Task.yield() }
    #expect(!second.worker.hasMail(for: id.recipient))
    second.worker.read { reader in
      let dropped = reader.cell(id)
      #expect(dropped.state() == nil)
      #expect(dropped.snapshotCount() == 0)
      #expect(dropped.pendingUpdates() == 0)
      #expect(dropped.checkpoints().isEmpty)
    }
    try await second.close()
  }

  @Test func aFolderReachesItsDocumentsAndNoSibling() async throws {
    let space = try space(clock: VirtualClock())
    let fs = await space.fs(.shared)
    let studio = try await space.addMachineV2(name: "studio", group: .shared).machine
    let other = try await space.addMachineV2(name: "other", group: .shared).machine
    let notes = "/_/machines/\(studio.id.rawValue)/notes.wmd"
    let theirs = "/_/machines/\(other.id.rawValue)/notes.wmd"
    let paths = ["/notes/plan.wmd", "/notes/a/b.wmd", "/notes-old.wmd", "/notes0.wmd", notes, theirs]
    for path in paths { _ = try await fs.write(path, bytes("One\n"), ifMatch: nil) }
    for path in ["/notes/plan.wmd", "/notes/a/b.wmd", notes] {
      var client = try await Client.join(space, path)
      try client.edit("One, edited\n")
      #expect(await client.next() == .control(.ack(count: 1)))
    }

    let underNotes = try SpacePath(validating: "/notes")
    let both = ["shared/notes/a/b.wmd", "shared/notes/plan.wmd"]
    #expect(space.dirtyDocuments(underNotes).sorted() == both)
    let underStudio = try SpacePath(validating: "/_/machines/\(studio.id.rawValue)")
    #expect(space.dirtyDocuments(underStudio) == ["shared" + notes])
  }

  @Test func aWakeThatFindsTheFileGoneLeavesNothingDueAndTheMailDeletesTheRows() async throws {
    let clock = VirtualClock()
    let space = try space(clock: clock)
    let file = await space.fs(.shared)
    _ = try await file.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    let id = DocumentCell.ID(.shared, try SpacePath(validating: plan))
    let lineage = try #require(space.worker.cell(id).lineage())

    // A delete that never tells the document: its rows outlive the file until the mail comes.
    let rev = try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.removeForDelayedDelivery(SpacePath(validating: plan), op: .delete)
    }
    try await fireIdleCheckpoint(clock)
    guard case .control(.error(code: .notFound, _))? = await client.next() else { Issue.record("a gone document kept its socket"); return }
    space.worker.read { reader in
      let cell = reader.cell(id)
      #expect(cell.nextWake() == nil, "a gone document stayed due")
      #expect(cell.state() != nil, "the rows go only by the mail")
    }
    space.worker.send(id).removed(rev, lineage: lineage)
    while space.worker.hasMail(for: id.recipient) { await Task.yield() }
    #expect(space.worker.cell(id).state() == nil)
  }

  @Test func anEditBetweenTheFileMutationAndTheMailIsRefused() async throws {
    let space = try makeSpace(clock: VirtualClock())
    _ = try await space.fs(.shared).write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)

    // The move's transaction, before its mail: the file is at another path and the rows still say it is here.
    _ = try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.removeForDelayedDelivery(SpacePath(validating: plan), op: .move, aux: "/archive/plan.wmd")
    }
    try client.edit("Hello there\n")
    guard case .control(.error(code: .notFound, _)) = await client.next() else {
      Issue.record("an edit after the file moved was taken")
      return
    }
    #expect(await client.next() == nil)
    #expect(try logRows(space) == 0, "a refused edit was logged")
  }

  @Test func aFolderWhereTheDocumentWasIsRefusedAndStaysUnexplained() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))

    try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) { cell in
      let rev = try cell.removeForDelayedDelivery(SpacePath(validating: plan), op: .delete)
      try cell.ensureAncestorDirectories(SpacePath(validating: plan + "/child.md"), rev: rev, mtime: SQLiteDateFormat.string(from: fixedDate))
    }
    try client.edit("Hello again\n")
    guard case .control(.error(code: .notFound, _)) = await client.next() else {
      Issue.record("a frame for a folder was taken")
      return
    }
    #expect(try logRows(space) == 1, "a refused frame was logged")
    await #expect(throws: SpaceError.notAFile(plan)) { _ = try await fs.read(plan) }
  }

  @Test func aDocumentRecreatedBeforeItsPredecessorsMailKeepsItsRows() async throws {
    let space = try makeSpace(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Old\n"), ifMatch: nil)
    var old = try await Client.join(space, plan)
    try old.edit("Old, edited\n")
    #expect(await old.next() == .control(.ack(count: 1)))

    let id = DocumentCell.ID(.shared, try SpacePath(validating: plan))
    let lineage = try #require(space.worker.cell(id).lineage())

    // The delete commits, and its mail is still on the way when the path is used again.
    let rev = try await space.worker.call(FilesCell.ID(GroupID.shared.rawValue)) {
      try $0.removeForDelayedDelivery(SpacePath(validating: plan), op: .delete)
    }
    var fresh = try await Client.join(space, plan, peer: "2", create: true)
    #expect(fresh.replica.text == "")
    try fresh.edit("New\n")
    var frame = await fresh.next()
    while frame.map({ if case .control(.peers) = $0 { true } else if case .control(.checkpoint) = $0 { true } else { false } }) == true { frame = await fresh.next() }
    #expect(frame == .control(.ack(count: 1)))

    space.worker.send(id).removed(rev, lineage: lineage)
    // A call on the same cell lands after the mail, and commits what the recreated document holds.
    _ = try? await space.worker.call(id) { $0.checkpoint() }
    #expect(text(try await fs.read(plan).1) == "New\n", "the old document's mail deleted the new one's edits")
  }

  @Test func aReadCommitsTheAckedEditAndLeavesTheStateAtTheFilesRevision() async throws {
    let space = try space(clock: VirtualClock())
    let fs = await space.fs(.shared)
    _ = try await fs.write(plan, bytes("Hello\n"), ifMatch: nil)
    var client = try await Client.join(space, plan)
    try client.edit("Hello there\n")
    #expect(await client.next() == .control(.ack(count: 1)))
    #expect(text(try await fs.read(plan).1) == "Hello there\n")
    try space.worker.read { reader in
      let state = reader.cell(DocumentCell.ID(.shared, try SpacePath(validating: plan))).fileRev() ?? -1
      let head = try reader.cell(FilesCell.ID(GroupID.shared.rawValue)).file(SpacePath(validating: plan))?.rev ?? -1
      #expect(state == head, "state file_rev \(state) vs head \(head)")
    }
  }

  @Test func aStepThatRollsBackLeavesTheReplicaBehindItsRows() throws {
    struct Boom: Error {}
    let replicas = DocumentReplicas()
    let live = LiveReplica(.wmd)
    try write(live, "# A\n\none\n", peer: 1)
    let snapshot = Data(try live.snapshot())
    let frontier = live.frontiers

    #expect(throws: Boom.self) {
      try replicas.with("shared/doc.wmd") { slot in
        let replica = try slot.take(frontier) { try LiveReplica(.wmd, snapshot: snapshot, updates: []) }
        let update = try #require(try replica.merge(text: "# A\n\ntwo\n", base: nil, peer: 2)?.update)
        try replica.importUpdate(update)
        throw Boom()
      }
    }

    let text = try replicas.with("shared/doc.wmd") { slot in
      try slot.take(frontier) { try LiveReplica(.wmd, snapshot: snapshot, updates: []) }.text
    }
    #expect(text == "# A\n\none\n")
  }
}

/// Writes `text` into `replica` as a client would: the update first, then its import.
private func write(_ replica: LiveReplica, _ text: String, base: Data? = nil, peer: UInt64) throws {
  let update = try #require(try replica.merge(text: text, base: base, peer: peer)?.update)
  try replica.importUpdate(update)
}

/// A client of one document, holding its own replica.
struct DocumentClient {
  let replica: LiveReplica
  let sink: AsyncStream<LiveInbound>.Continuation
  var outbound: AsyncStream<LiveOutbound>.AsyncIterator
  var nextPeer: UInt64

  static func connect(
    _ space: Space, _ path: String, group: GroupID = .shared, access: LiveAccess = .write, peer: String = "1", create: Bool = false,
    reauthorize: @escaping @Sendable () async -> LiveAccess? = { .write },
  ) async -> DocumentClient {
    let (frames, sink) = AsyncStream.makeStream(of: LiveInbound.self)
    let outbound = await space.liveChannel(
      group, try! SpacePath(validating: path), peer: peer, name: "peer " + peer, access: access, create: create, frames: frames,
      reauthorize: reauthorize,
    )
    return DocumentClient(replica: LiveReplica(path.hasSuffix(".canvas") ? .canvas : .wmd), sink: sink, outbound: outbound.makeAsyncIterator(), nextPeer: UInt64(peer)! << 32)
  }

  /// Through welcome, the catch-up and synced.
  static func join(
    _ space: Space, _ path: String, group: GroupID = .shared, access: LiveAccess = .write, peer: String = "1", create: Bool = false,
    reauthorize: @escaping @Sendable () async -> LiveAccess? = { .write },
  ) async throws -> DocumentClient {
    var client = await connect(space, path, group: group, access: access, peer: peer, create: create, reauthorize: reauthorize)
    // A roster wanted by an older connection may reach this one first; a client ignores controls until its welcome.
    var weathered: LiveOutbound?
    var welcomed = false
    while let frame = await client.next() {
      switch frame {
      case .control(.welcome):
        welcomed = true
      case .control(.error):
        weathered = frame
      default:
        weathered = frame
        continue
      }
      break
    }
    guard welcomed else { throw Unexpected(frame: weathered) }
    client.send(.sync(versionVector: Array(client.replica.versionVector)))
    var settled: LiveOutbound?
    while let frame = await client.next() {
      switch frame {
      case let .frame(.update(update)):
        try client.replica.importUpdate(Data(update))
        continue
      case .frame(.synced):
        settled = frame
      default:
        continue
      }
      break
    }
    guard case .frame(.synced)? = settled else { throw Unexpected(frame: settled) }
    return client
  }

  mutating func next() async -> LiveOutbound? { await outbound.next() }

  mutating func nextNonRoster() async -> LiveOutbound? {
    var frame = await next()
    while case .control(.peers)? = frame { frame = await next() }
    return frame
  }

  func send(_ frame: LiveFrame) { sink.yield(.binary(frame.bytes)) }

  mutating func edit(_ markdown: String) throws {
    nextPeer += 1
    let update = try #require(try replica.merge(text: markdown, base: nil, peer: nextPeer)?.update)
    try replica.importUpdate(update)
    send(.update(Array(update)))
  }

  func leave() { sink.finish() }

  struct Unexpected: Error, CustomStringConvertible {
    var frame: LiveOutbound?
    var description: String { "unexpected frame \(String(describing: frame))" }
  }
}

extension FilesCell {
  mutating func removeForDelayedDelivery(_ path: SpacePath, op: JournalOp, aux: String? = nil) throws -> Int64 {
    let rev = try mintRevision(SQLiteDateFormat.string(from: fixedDate), attribution: nil)
    try appendVersion(path.rawValue, rev: rev, kind: nil, hash: nil, op: op, aux: aux)
    let key = id.key
    try db.execute(FSHeadRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.delete())
    try removeIndex(path)
    return rev
  }
}

extension Space {
  nonisolated func dirtyDocuments(_ path: SpacePath) -> [String] {
    worker.cell(FilesCell.ID(GroupID.shared.rawValue)).subtree(path).compactMap { head in
      let path = try! SpacePath(validating: head.path)
      return path.isLive && worker.cell(DocumentCell.ID(.shared, path)).dirty() ? DocumentCell.key(.shared, path) : nil
    }
  }
}
