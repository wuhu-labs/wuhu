import DequeModule

/// The isolation an incarnation runs in: an actor on the addressable's lane. It holds nothing but its ``Incarnation`` and only brings work from outside (pokes, settlements, timers, effects) onto the lane.
actor Host {
  let incarnation: Incarnation
  private nonisolated let lane: Lane

  init(_ incarnation: sending Incarnation, scheduler: any Scheduler) {
    lane = Lane(scheduler: scheduler)
    self.incarnation = incarnation
    incarnation.host = self
    lane.onDrain { [weak self] in self?.assumeIsolated { $0.incarnation.seal() } }
  }

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    lane.asUnownedSerialExecutor()
  }

  func run<Value: Sendable>(_ body: @Sendable (Incarnation) async -> Value) async -> Value {
    await body(incarnation)
  }

  func pull() {
    incarnation.pull()
  }

  func drain() async {
    await incarnation.drain()
  }

  /// The output gate for effects, which may come from child tasks off the lane.
  func gate(run: UInt64) async throws {
    precondition(incarnation.running == run, "\(incarnation.address) used its effects after the start that took them returned")
    try await incarnation.gate()
  }

  /// Returns once the inbox holds a message.
  func mail() async throws {
    while incarnation.inbox.isEmpty {
      try await incarnation.park(until: nil, wakesOnMail: true)
    }
  }
}

/// Runs a body on an incarnation's lane, from anywhere.
struct Hop: Sendable {
  let host: Host
  let worker: Worker

  @discardableResult
  func callAsFunction(_ body: @escaping @Sendable (Incarnation) async -> Void) -> Task<Void, Never> {
    worker.task { await host.run(body) }
  }
}

/// What differs between a cell and a job: how it boots, what a delivery does and what a socket event does.
struct Lifecycle {
  let boot: (Incarnation) -> Void
  let deliver: (Incarnation, Mail) -> Void
  let socket: (Incarnation, Attachment, Attachment.Inbound) -> Void
}

/// One incarnation of an addressable: its tables, what it wrote since the last commit, the epochs in flight and the outputs waiting on them. Not `Sendable`: it lives in its ``Host``, touched only on the lane, by the host or by the addressable's own code. After a failed epoch it is dead, and the next delivery hydrates a fresh one from durable state.
final class Incarnation {
  enum Output {
    case waiter(CheckedContinuation<Void, any Error>)
    case emit(@Sendable () async -> Void)
    case frame(Attachment, any Sendable)
    case close(Attachment)
  }

  /// Layered: a database of its own over a page file, sealed into epochs. Shared: the shared database's writer, lent for one step at a time.
  enum Tables {
    case layered(PageFile, Connection)
    case shared
  }

  let address: String
  let key: String
  let lease: Lease
  let worker: Worker
  weak var host: Host?
  private let tables: Tables
  private var open: Connection?
  private let schema: [String]
  private let lifecycle: Lifecycle

  private var writes: [Write] = []
  private var sealed: UInt64 = 0
  private var durable: UInt64 = 0
  private var held = Deque<(epoch: UInt64, output: Output)>()
  private var parked: [UInt64: (wakesOnMail: Bool, continuation: CheckedContinuation<Void, any Error>)] = [:]
  private var parkings: UInt64 = 0
  private var booted = false
  private(set) var retiring = false
  private var repoke = false
  private(set) var dead = false
  /// Mail whose call or receive began in this incarnation, until its consumption is durable.
  private var started: Set<Int64> = []

  var idleGeneration = 0
  /// A cell's `nextWake()` as last recorded (durable when claimed), and which arming of its timer is current.
  var wakeAt: Instant?
  var wakeGeneration = 0
  var inbox = Deque<Mail>()
  /// A job's `Live`, while its `start` loop runs.
  weak var liveJob: AnyObject?
  var startTask: Task<Void, Never>?
  /// Which run of a job's `start` is live, if one is: effects taken from an earlier run trap.
  var running: UInt64?
  /// Outputs of the call in progress, held when it returns and dropped if it throws.
  private var pending: [Output]?
  /// Socket deliveries waiting for this retiring incarnation to leave, so they reach the next one.
  private var leaving: [CheckedContinuation<Void, Never>] = []
  private var left = false

  init(address: String, key: String, lease: Lease, pageCount: UInt32, wakeAt: Instant?, worker: Worker, schema: [String], lifecycle: Lifecycle) throws {
    self.address = address
    self.key = key
    self.lease = lease
    self.wakeAt = wakeAt
    self.worker = worker
    self.schema = schema
    self.lifecycle = lifecycle
    if worker.store.file != nil {
      let store = worker.store
      let file = PageFile(pageCount: pageCount, writable: true) { try store.page(lease.id, $0) }
      tables = try .layered(file, Connection(file: file, owner: key))
    } else {
      tables = .shared
    }
  }

  func record(_ write: Write) {
    writes.append(write)
  }

  func output(_ output: Output) {
    if pending != nil { pending!.append(output) } else { hold([output]) }
  }

  /// Where a statement runs now; `nil` between the steps of the shared backend.
  private var connection: Connection? {
    switch tables {
    case let .layered(_, db): db
    case .shared: open
    }
  }

  var hostConnection: AnyObject? {
    open?.host
  }

  /// A read as `owner` on the shared step open now, `nil` when none is: a read handle taken inside a step reads here, since the outer store's reader would wait on the write this step holds.
  func readOpen(as owner: String, _ sql: String, _ arguments: [Value]) -> [Row]? {
    guard case .shared = tables, let open else { return nil }
    let own = open.owner
    open.owner = owner
    defer { open.owner = own }
    return open.read(sql, arguments)
  }

  /// Between shared steps, each read is a fresh one.
  func read(_ sql: String, _ arguments: [Value]) -> [Row] {
    if let connection { return connection.read(sql, arguments) }
    do { return try worker.store.read(owner: key) { $0.read(sql, arguments) } } catch { preconditionFailure("\(sql): \(error)") }
  }

  /// Between shared steps, a write is a step of its own.
  func write(_ sql: String, _ arguments: [Value]) -> Result<Void, WriteFailure> {
    if let connection { return connection.write(sql, arguments) }
    do {
      try step { try connection!.write(sql, arguments).get() }
      return .success(())
    } catch let failure as WriteFailure {
      return .failure(failure)
    } catch {
      return .failure(.storage(error))
    }
  }

  /// One durable step. If `body` throws, what it wrote and staged is undone. Layered, it is a savepoint of the inner database, sealed at the next drain. Shared, it is one write transaction that also commits everything staged before it and checks the fence, and is durable when it returns; a failed commit ends the incarnation.
  func step<T>(_ body: () throws -> T) throws -> T {
    guard !dead else { throw Evicted(address: address) }
    let staged = writes.count
    guard case .shared = tables else {
      do {
        return try connection!.transaction(body)
      } catch {
        writes.removeSubrange(staged...)
        throw error
      }
    }
    precondition(open == nil, "steps do not nest")
    var epoch: Epoch?
    let value: T
    do {
      value = try worker.store.write(owner: key) { db in
        open = db
        defer { open = nil }
        let value = try body()
        epoch = Epoch(address: address, lease: lease, number: sealed + 1, pages: [:], pageCount: 0, writes: writes)
        try worker.store.commit(epoch!, on: db, now: worker.scheduler.now, leaseDuration: worker.options.leaseDuration)
        return value
      }
    } catch {
      if epoch == nil { writes.removeSubrange(staged...) } else { fail(error) }
      throw error
    }
    writes = []
    sealed += 1
    settled(epoch!, .success(()))
    return value
  }

  /// Runs `body` as one durable step: if it throws, everything it wrote, sent and emitted is rolled back, and it returns false.
  @discardableResult
  func atomically(_ body: () throws -> Void) -> Bool {
    pending = []
    var committed = true
    do {
      try step(body)
    } catch {
      committed = false
      pending = []
      if !dead { worker.log.error("\(address) rolled back a call: \(error)") }
    }
    hold(pending!)
    pending = nil
    return committed
  }

  /// What outside callbacks use to get back onto the lane.
  var hop: Hop {
    Hop(host: host!, worker: worker)
  }

  func gate() async throws {
    guard !dead else { throw Evicted(address: address) }
    try await withCheckedThrowingContinuation { hold([.waiter($0)]) }
  }

  private var dirty: Bool {
    if case let .layered(file, _) = tables, file.isDirty { return true }
    return !writes.isEmpty
  }

  /// Each output waits for the epoch holding everything written before it.
  private func hold(_ outputs: [Output]) {
    let need = dirty ? sealed + 1 : sealed
    for output in outputs {
      if dead { abandon(output) } else if durable >= need { release(output) } else { held.append((need, output)) }
    }
  }

  private func release(_ output: Output) {
    switch output {
    case let .waiter(continuation): continuation.resume()
    case let .emit(emit): worker.task { await emit() }
    case let .frame(attachment, frame): attachment.push(frame)
    case let .close(attachment): attachment.end()
    }
  }

  private func abandon(_ output: Output) {
    switch output {
    case let .waiter(continuation): continuation.resume(throwing: Evicted(address: address))
    case .emit: break
    case let .frame(attachment, _), let .close(attachment): attachment.end()
    }
  }

  /// Runs when the lane drains: everything written since the last seal becomes one epoch, or, shared, one step.
  func seal() {
    guard dirty, !dead else { return }
    guard case let .layered(file, _) = tables else {
      _ = try? step {}
      return
    }
    sealed += 1
    let epoch = Epoch(address: address, lease: lease, number: sealed, pages: file.seal(sealed), pageCount: file.pageCount, writes: writes)
    writes = []
    let hop = hop
    worker.shipper.ship(epoch) { result in
      hop { $0.settled(epoch, result) }
    }
  }

  private func settled(_ epoch: Epoch, _ result: Result<Void, any Error>) {
    guard !dead else { return }
    guard case .success = result else { return die() }
    // Settlements of one batch arrive as separate tasks, in any order.
    durable = max(durable, epoch.number)
    if case let .layered(file, _) = tables { file.markDurable(through: durable) }
    for write in epoch.writes {
      switch write {
      case let .consume(mail): started.remove(mail)
      case let .send(envelope): worker.poke(envelope.recipient)
      case let .create(job, _): worker.poke(job)
      default: break
      }
    }
    while let first = held.first, first.epoch <= durable {
      release(held.removeFirst().output)
    }
    if retiring, durable == sealed, !dirty {
      leave(repoke: repoke)
    }
  }

  /// The disk failed under this incarnation, or its lease is gone: what it holds can no longer become durable.
  func fail(_ error: any Error) {
    guard !dead else { return }
    worker.log.error("\(address) lost its storage: \(error)")
    die()
  }

  private func die() {
    dead = true
    while let first = held.popFirst() {
      abandon(first.output)
    }
    for token in parked.keys.sorted() {
      unpark(token, throwing: Evicted(address: address))
    }
    startTask?.cancel()
    leave(repoke: true)
  }

  private func leave(repoke: Bool) {
    left = true
    worker.remove(host!, at: address, repoke: repoke)
    for continuation in leaving {
      continuation.resume()
    }
    leaving = []
  }

  /// Hands this incarnation's due mail to the addressable, booting it first. A poke or a scan can hand over the same row again; `started` makes that harmless.
  func pull() {
    guard !dead else { return }
    guard !retiring else {
      repoke = true
      return
    }
    boot()
    for mail in worker.mail(for: address) where started.insert(mail.id).inserted {
      lifecycle.deliver(self, mail)
    }
  }

  /// Hands a socket event to the addressable. `false` means this incarnation is gone or leaving, and the caller should find the next one.
  func socket(_ inbound: Attachment.Inbound, from attachment: Attachment) async -> Bool {
    guard !dead, !left else { return false }
    if retiring {
      await withCheckedContinuation { leaving.append($0) }
      return false
    }
    boot()
    lifecycle.socket(self, attachment, inbound)
    return true
  }

  private func boot() {
    guard !booted else { return }
    booted = true
    if case let .layered(_, db) = tables { migrate(db, schema) }
    lifecycle.boot(self)
  }

  func drain() async {
    startTask?.cancel()
    await startTask?.value
    try? await gate()
  }

  /// The incarnation leaves once `write` and everything before it are durable.
  func retire(_ write: Write) {
    retiring = true
    record(write)
  }

  /// Without a deadline, only mail or cancellation ends the wait.
  func park(until deadline: Instant?, wakesOnMail: Bool) async throws {
    guard !dead else { throw Evicted(address: address) }
    parkings += 1
    let token = parkings
    let hop = hop
    if let deadline {
      worker.scheduler.at(deadline) {
        hop { $0.unpark(token) }
      }
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { parked[token] = (wakesOnMail, $0) }
    } onCancel: {
      hop { $0.unpark(token, throwing: CancellationError()) }
    }
  }

  func wakeForMail() {
    for token in parked.keys.sorted() where parked[token]!.wakesOnMail {
      unpark(token)
    }
  }

  private func unpark(_ token: UInt64, throwing error: (any Error)? = nil) {
    guard let waiter = parked.removeValue(forKey: token) else { return }
    if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
  }
}

/// Brings an addressable's database up to its type's schema. A copy that is never sealed, such as a read handle's, is migrated the same way, so a reader of a cell that has never booted sees a fresh one.
func migrate(_ db: Connection, _ schema: [String]) {
  do {
    let applied = Int(try db.rows("PRAGMA user_version")[0]["user_version"].integer!)
    precondition(applied <= schema.count, "lost schema steps: \(applied) applied, \(schema.count) declared")
    guard applied < schema.count else { return }
    try db.transaction {
      for statement in schema[applied...] {
        try db.execute(statement)
      }
      try db.execute("PRAGMA user_version = \(schema.count)")
    }
  } catch {
    preconditionFailure("migration failed: \(error)")
  }
}
