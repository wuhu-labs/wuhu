import JSONValue
import struct SpaceContract.GroupID
import SpaceFS
import SpaceSQL
import StructuredQueries
import Synchronization
import Wuwei
import WuweiQueries

/// A statement's snapshots as a client stream: the rows as they are, then each changed snapshot after the watch's throttle.
enum RowsStream: Socket {
  struct Opening: Sendable {
    var sql: String
    var parameters: [JSONValue]
    var throttle: Duration
    var viewer: String?
    var principal: Principal
  }

  typealias Outgoing = Rows
}

/// A group's file changes as a client stream: one journal revision at a time, from the revision the client resumes after.
enum FileStream: Socket {
  struct Opening: Sendable {
    var glob: String
    var group: GroupID
    var after: Int
    var principal: Principal
  }

  typealias Outgoing = FSCommit
}

/// Starts a region observation on `tables` that wakes `wakes` on every change, and returns what cancels it.
typealias RegionSource = @Sendable (_ tables: [String], _ wakes: AsyncStream<Void>.Continuation) -> @Sendable () -> Void

/// The space's observation job is not this process's to host: another process holds it, or the space is closed.
public struct ObservationsUnavailable: Error, Equatable, Sendable {
  public init() {}
}

/// What the observation job needs of the space, provided to its worker: the database its watches read, the read pool their statements run on, the clock their throttles wait on, and the region observations that wake them.
struct ObservationSources: Sendable {
  let reads: ReadPool
  let clock: any Clock<Duration>
  let regions: RegionSource
}

/// The space's one observation job: client sockets and durable agent SQL slots run side by side. A drain closes sockets for reconnect; slots hydrate from the job's rows and suppress unchanged reruns with their marker.
@Job
struct ObservationJob {
  typealias Message = ObservationMail

  static let schema = [
    "CREATE TABLE observation_slots (\(ownerColumn), slot TEXT NOT NULL, statement TEXT NOT NULL, principal_source TEXT NOT NULL, recipient TEXT NOT NULL, marker TEXT, UNIQUE (slot))",
  ]

  enum WatchID: Hashable, Sendable {
    case socket(Int)
    case slot(String)
  }

  struct Params: Codable {}

  static let address = ObservationJob.ID("streams")

  /// The watch set: each attached socket's watch, the results it has not heard yet, and a wake registered once per run of the lane loop and of the long effect, so a result or an attach that lands while either looks is never missed.
  final class State: Sendable {
    struct Registration: Hashable, Sendable {
      let id: WatchID
      let number: Int
    }

    enum Watch: Sendable {
      case rows(RowsStream.Opening)
      case slot(ObservationWatch)
      case files(FileStream.Opening)
    }

    enum Published: Sendable {
      case rows(Rows)
      case commit(FSCommit)
      case closed
      case failed(String)
    }

    /// One run of a watch: the streams it hears its changes on, and the way this state ends that run.
    struct Live: Sendable {
      let watch: Watch
      let wakes: AsyncStream<Void>
      let wake: AsyncStream<Void>.Continuation
      let retired: AsyncStream<Void>
      let retire: AsyncStream<Void>.Continuation
    }

    private struct Entry {
      let registration: Registration
      let watch: Watch
      var retire: AsyncStream<Void>.Continuation?
    }

    private struct Contents {
      var watches: [WatchID: Entry] = [:]
      var results: [(registration: Registration, result: Published)] = []
      var nextRegistration = 0
      var resultWake: AsyncStream<Void>
      var resultWaiter: AsyncStream<Void>.Continuation
      var watchWake: AsyncStream<Void>
      var watchWaiter: AsyncStream<Void>.Continuation

      mutating func remove(_ id: WatchID) -> AsyncStream<Void>.Continuation? {
        guard let entry = watches.removeValue(forKey: id) else { return nil }
        results.removeAll { $0.registration == entry.registration }
        return entry.retire
      }
    }

    private let contents: Mutex<Contents>

    init() {
      let results = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      let changes = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      contents = Mutex(Contents(resultWake: results.stream, resultWaiter: results.continuation, watchWake: changes.stream, watchWaiter: changes.continuation))
    }

    /// Opens this run of the lane loop: a result published at any point after this wakes it, because the wake is registered before the check for one.
    func wakingResults() {
      let (stream, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      contents.withLock { contents in
        contents.resultWake = stream
        contents.resultWaiter = wake
      }
    }

    /// The same for the long effect, before it looks at the watch set.
    func wakingWatches() {
      let (stream, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      contents.withLock { contents in
        contents.watchWake = stream
        contents.watchWaiter = wake
      }
    }

    func register(_ id: WatchID, _ watch: Watch) {
      let waiter = contents.withLock { contents -> AsyncStream<Void>.Continuation in
        precondition(contents.watches[id] == nil, "\(id) is watched twice")
        contents.nextRegistration += 1
        contents.watches[id] = Entry(registration: Registration(id: id, number: contents.nextRegistration), watch: watch)
        return contents.watchWaiter
      }
      waiter.yield(())
    }

    func remove(_ id: WatchID) {
      let retired = contents.withLock { $0.remove(id) }
      retired?.finish()
      contents.withLock { $0.watchWaiter }.yield(())
    }

    func watch(_ id: WatchID) -> Watch? {
      contents.withLock { $0.watches[id]?.watch }
    }

    func watching() -> Set<Registration> {
      contents.withLock { Set($0.watches.values.map(\.registration)) }
    }

    /// The streams this run of the watch hears its changes on, and the way this state ends this run; nil once the watch is gone.
    func listening(_ registration: Registration) -> Live? {
      let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      let (retired, retire) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      let watch = contents.withLock { contents -> Watch? in
        guard let entry = contents.watches[registration.id], entry.registration == registration else { return nil }
        contents.watches[registration.id]?.retire = retire
        return entry.watch
      }
      guard let watch else { return nil }
      return Live(watch: watch, wakes: wakes, wake: wake, retired: retired, retire: retire)
    }

    /// A rows watch keeps only its newest snapshot; a file watch drops none.
    func publish(_ registration: Registration, _ result: Published) {
      let waiter = contents.withLock { contents -> AsyncStream<Void>.Continuation? in
        guard contents.watches[registration.id]?.registration == registration else { return nil }
        if case .rows = result { contents.results.removeAll { $0.registration == registration } }
        contents.results.append((registration, result))
        return contents.resultWaiter
      }
      waiter?.yield(())
    }

    /// The results waiting, or the next to arrive; nil once this waiting run is cancelled.
    func nextResults() async -> Bool {
      while true {
        let (waiting, wake) = contents.withLock { (!$0.results.isEmpty, $0.resultWake) }
        if waiting { return true }
        var woken = wake.makeAsyncIterator()
        guard await woken.next() != nil else { return false }
      }
    }

    func takeResults() -> [(registration: Registration, result: Published)] {
      contents.withLock { contents in
        defer { contents.results.removeAll() }
        return contents.results
      }
    }

    /// True once a watch registers or goes; false once this waiting run is cancelled.
    func changed() async -> Bool {
      let wake = contents.withLock { $0.watchWake }
      var announced = wake.makeAsyncIterator()
      return await announced.next() != nil
    }
  }

  static func hydrate(ctx: inout JobContext<Self>) throws -> State {
    let state = State()
    for row in ctx.db.rows(ObservationRow.all) {
      let watch = row.watch
      state.register(.slot(row.slot), .slot(watch))
    }
    return state
  }

  /// Registers the socket's watch; its first read is a result like any other.
  func attached(_ socket: SocketHandle<RowsStream>) {
    state.register(.socket(socket.id), .rows(socket.opening))
  }

  func attached(_ socket: SocketHandle<FileStream>) {
    state.register(.socket(socket.id), .files(socket.opening))
  }

  /// The socket went: its watch goes with it, ending its children where they stand.
  func closed(_ socket: SocketHandle<RowsStream>) {
    state.remove(.socket(socket.id))
  }

  func closed(_ socket: SocketHandle<FileStream>) {
    state.remove(.socket(socket.id))
  }

  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    var context = ctx
    let state = state
    let sources = ctx.dependency(ObservationSources.self)
    let files = ctx.dependency(FileWatchReads.self)
    let effects = context.effects
    async let _: Void = effects.effect { await Self.watchAll(state, sources, files) }
    while true {
      state.wakingResults()
      // The wait is the effect's: it holds the quiesce gate and refuses a dead incarnation before the lane goes on to send.
      let results: [(registration: State.Registration, result: State.Published)]
      switch try await context.race({ _, _ in await state.nextResults() }, until: { _ in true }) {
      case let .message(.watch(watch)):
        let key = watch.slot.key
        let row = ObservationRow(watch)
        try context.db.execute(ObservationRow.insert { row } onConflict: { $0.slot })
        if state.watch(.slot(key)) == nil { state.register(.slot(key), .slot(watch)) }
        continue
      case let .message(.unwatch(slot)):
        let key = slot.key
        try context.db.execute(ObservationRow.where { $0.slot.eq(key) }.delete())
        state.remove(.slot(key))
        continue
      case let .finished(waiting):
        guard waiting else { throw CancellationError() }
        results = state.takeResults()
      }
      let rows = Dictionary(uniqueKeysWithValues: context.sockets(of: RowsStream.self).map { (WatchID.socket($0.id), $0) })
      let files = Dictionary(uniqueKeysWithValues: context.sockets(of: FileStream.self).map { (WatchID.socket($0.id), $0) })
      for (registration, result) in results {
        let id = registration.id
        if case let .slot(key) = id {
          guard let row = context.db.rows(ObservationRow.where { $0.slot.eq(key) }).first else { continue }
          let watch = row.watch
          switch result {
          case let .rows(snapshot):
            let marker = rowsMarker(snapshot)
            if marker != row.marker {
              context.send(.observed(watch.slot, snapshot, marker), to: watch.recipient)
              try context.db.execute(ObservationRow.where { $0.slot.eq(key) }.update { $0.marker = #bind(marker) })
            }
          case let .failed(reason): context.send(.failed(watch.slot, reason), to: watch.recipient)
          case .commit, .closed: preconditionFailure("a slot only observes rows")
          }
        } else {
          switch result {
          case let .rows(snapshot): rows[id]?.send(snapshot)
          case let .commit(commit): files[id]?.send(commit)
          case .closed:
            if let socket = rows[id] { socket.close() } else if let socket = files[id] { socket.close() }
          case .failed: preconditionFailure("a socket closes on failure")
          }
        }
      }
    }
  }

  /// The long effect of one incarnation: every registered watch runs as its own child, from the moment it registers to the moment it goes.
  private static func watchAll(_ state: State, _ sources: ObservationSources, _ files: FileWatchReads) async {
    // Opened before the watch set is read, so an attach that lands while it looks is not missed.
    state.wakingWatches()
    await withDiscardingTaskGroup { group in
      var running: Set<State.Registration> = []
      while !Task.isCancelled {
        let watching = state.watching()
        for id in watching.subtracting(running) {
          guard let live = state.listening(id) else { continue }
          running.insert(id)
          group.addTask { await Self.run(id, live, state, sources, files) }
        }
        running.formIntersection(watching)
        guard await state.changed() else { break }
      }
      group.cancelAll()
    }
  }

  /// One watch: its own body beside the stream that ends it where it stands, so a `closed` need not wait out a throttle.
  private static func run(_ id: State.Registration, _ live: State.Live, _ state: State, _ sources: ObservationSources, _ files: FileWatchReads) async {
    enum Ending { case retired, ended }
    await withTaskGroup(of: Ending.self) { group in
      group.addTask {
        switch live.watch {
        case let .rows(opening): try? await rows(opening, sources, live.wakes, live.wake) { state.publish(id, .rows($0)) }
        case let .slot(watch):
          do {
            try await rows(.init(sql: watch.statement, parameters: [], throttle: .zero, viewer: nil, principal: .shared(.publicReader)), sources, live.wakes, live.wake, principal: watch.principal) { state.publish(id, .rows($0)) }
          } catch is CancellationError {} catch { state.publish(id, .failed(String(describing: error))) }
        case let .files(opening): try? await Self.files(opening, sources, files, live.wakes, live.wake) { state.publish(id, .commit($0)) }
        }
        return .ended
      }
      group.addTask {
        var retired = live.retired.makeAsyncIterator()
        _ = await retired.next()
        return .retired
      }
      let ending = await group.next()!
      group.cancelAll()
      // Whatever ends a watch but its socket going is its end: the client reconnects.
      if case .ended = ending, !Task.isCancelled {
        if case .slot = live.watch {} else { state.publish(id, .closed) }
      }
    }
  }

  static func rows(
    _ opening: RowsStream.Opening,
    _ sources: ObservationSources,
    _ wakes: AsyncStream<Void>,
    _ wake: AsyncStream<Void>.Continuation,
    principal: ObservationPrincipal? = nil,
    publish: @Sendable (Rows) -> Void,
  ) async throws {
    let arguments = try Space.bound(opening.parameters)
    func read() async throws -> (Rows, ReadTables) {
      do {
        let (rows, tables) = try await sources.reads.run(opening.sql, arguments: arguments, resolving: { snapshot in
          let principal = try principal?.resolve(in: snapshot) ?? opening.principal
          return try GroupAccess.scope(for: principal, viewer: opening.viewer, in: snapshot)
        })
        return (Rows(columns: rows.columns, decltypes: rows.decltypes, rows: rows.rows.map { $0.map(Cells.cell(from:)) }), tables)
      } catch let error as ReadError { throw SpaceError(error) }
    }
    // A created or retired table writes its registry row; one dropped leaves no row events of its own, so a watch tracks the registry to hear it.
    func watch(_ names: [String]) -> () -> Void { sources.regions(names + ["tables"], wake) }
    var (last, tables) = try await read()
    var observation = watch(tables.names.sorted())
    defer { observation() }
    // Register before the catch-up read, so a commit between discovery and observation is not missed.
    let (snapshot, current) = try await read()
    last = snapshot
    if current != tables {
      tables = current
      observation()
      observation = watch(tables.names.sorted())
      wake.yield(())
    }
    publish(last)
    for await _ in wakes {
      if opening.throttle != .zero { try await sources.clock.sleep(for: opening.throttle) }
      let (snapshot, current) = try await read()
      if current != tables {
        tables = current
        observation()
        observation = watch(tables.names.sorted())
        wake.yield(())
      }
      if snapshot != last {
        last = snapshot
        publish(snapshot)
      }
    }
    try Task.checkCancellation()
    throw WatchEnded()
  }

  /// The journal after the cursor on every wake, one commit per revision in order. A principal that no longer reads the group ends the watch instead of going quiet.
  static func files(
    _ opening: FileStream.Opening,
    _ sources: ObservationSources,
    _ reader: FileWatchReads,
    _ wakes: AsyncStream<Void>,
    _ wake: AsyncStream<Void>.Continuation,
    publish: @Sendable (FSCommit) -> Void,
  ) async throws {
    var cursor = opening.after
    let observation = sources.regions(["fs_versions", "groups", "group_roles"], wake)
    defer { observation() }
    func catchUp() throws {
      while true {
        let page = try reader.page(opening, after: cursor)
        if let last = page.cursor { cursor = last }
        for commit in page.commits {
          let events = commit.events.filter { matches(opening.glob, $0) }
          if !events.isEmpty { publish(FSCommit(group: commit.group, rev: commit.rev, events: events)) }
        }
        if !page.full { return }
      }
    }
    try catchUp()
    for await _ in wakes {
      try catchUp()
    }
  }

  /// Whether the glob names either end of the event: a move matches at its destination or its source.
  private static func matches(_ glob: String, _ event: MutationEvent) -> Bool {
    Glob.matches(glob, event.path) || event.from.map { Glob.matches(glob, $0) } ?? false
  }
}

/// The watch ends: a refused statement, a failed read, or a group the principal no longer reads.
private struct WatchEnded: Error {}

@Table("observation_slots")
private struct ObservationRow: Owned {
  let slot: String
  let statement: String
  @Column("principal_source") let principal: String
  let recipient: String
  var marker: String?

  init(_ watch: ObservationWatch) {
    slot = watch.slot.key
    statement = watch.statement
    principal = encoded(watch.principal)
    recipient = encoded(watch.recipient)
    marker = watch.marker
  }

  var watch: ObservationWatch {
    ObservationWatch(slot: decoded(ObservationSlot.self, slot), statement: statement, principal: decoded(ObservationPrincipal.self, principal), recipient: decoded(Recipient<ObservationReply>.self, recipient), marker: marker)
  }
}
