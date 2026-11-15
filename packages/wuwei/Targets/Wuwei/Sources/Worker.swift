import GRDBSQLite
import Logging
import Synchronization

/// The addressable types a worker can host.
public struct Registration: Sendable {
  let kind: String
  let writerLabel: String
  let isJob: Bool
  let schema: [String]
  let owned: [String: String]
  let lifecycle: @Sendable (Claim) -> Lifecycle

  public static func cell<C: Cell>(_: C.Type) -> Registration {
    Registration(kind: C.kind, writerLabel: "cell:\(C.kind)", isJob: false, schema: C.schema, owned: C.owned) { _ in .cell(C.self) }
  }

  public static func job<J: Job>(_: J.Type) -> Registration {
    Registration(kind: J.kind, writerLabel: "job:\(J.kind)", isJob: true, schema: J.schema, owned: J.owned) { .job(J.self, row: $0.job!) }
  }

  func host(_ worker: Worker, _ claim: Claim) throws -> Host {
    try Host(
      Incarnation(
        address: "\(kind)/\(claim.key)", key: claim.key, lease: claim.lease, pageCount: claim.pageCount, wakeAt: claim.wakeAt,
        worker: worker, writerLabel: writerLabel, schema: schema, lifecycle: lifecycle(claim),
      ),
      scheduler: worker.scheduler,
    )
  }
}

struct Claim: Sendable {
  let key: String
  let lease: Lease
  let pageCount: UInt32
  let wakeAt: Instant?
  let job: JobRow?
}

/// One process's runtime: it claims addressables, hosts them, ships their epochs and scans the outer store for mail and jobs that nobody is serving.
public final class Worker: Sendable {
  public struct Options: Sendable {
    public var leaseDuration: Duration = .seconds(10)
    public var scanInterval: Duration = .seconds(1)
    public var cellIdle: Duration = .seconds(30)
    public var retryDelay: Duration = .seconds(1)

    public init() {}
  }

  private struct Hosts: Sendable {
    var live: [String: Host] = [:]
    var claiming = true
    var holding = true
    var started = false
    var scanning = false
    var quiescence: Task<Void, Never>?
    var quiesced = false
    var holds: [UInt64: (address: String?, wake: AsyncStream<Void>.Continuation)] = [:]
    var nextHold: UInt64 = 0

    mutating func endHolds() {
      holding = false
      for hold in holds.values { hold.wake.finish() }
      holds = [:]
    }
  }

  private enum Hosting: Sendable {
    case live(Host)
    case draining
    case unavailable
  }

  private enum Claimed {
    case claimed(Claim)
    case draining
    case refused
  }

  private struct Sockets {
    var attached: [String: [Attachment]] = [:]
    var count = 0
  }

  public let id: String
  public let scheduler: any Scheduler
  private let born: Instant
  let store: OuterStore
  let shipper: Shipper
  let options: Options
  let log = Logger(label: "wuwei")
  private let registrations = Mutex<[String: Registration]>([:])
  private let dependencies: Mutex<Dependencies>
  private let hosts = WriterWaitingLock(Hosts())
  private let sockets = Mutex(Sockets())
  private let maintaining = WriterWaitingLock(true)

  public init(id: String, storage: Storage, scheduler: any Scheduler, registrations: [Registration] = [], dependencies: Dependencies = Dependencies(), options: Options = Options()) {
    self.id = id
    self.scheduler = scheduler
    self.dependencies = Mutex(dependencies)
    self.options = options
    born = scheduler.now
    store = OuterStore(storage)
    shipper = Shipper(store: store, scheduler: scheduler, leaseDuration: options.leaseDuration)
    for registration in registrations {
      register(registration)
    }
  }

  /// Adds a kind this worker hosts, before it starts. On the shared backend, the kind's tables are brought up to its schema here.
  public func register(_ registration: Registration) {
    precondition(!registration.kind.contains("/"), "a kind is the part of an address before its first slash")
    precondition(!isStarted, "a worker takes its kinds before it starts")
    registrations.withLock { registrations in
      precondition(registrations.updateValue(registration, forKey: registration.kind) == nil, "\(registration.kind) is registered twice")
    }
    if store.file == nil { store.prepare(kind: registration.kind, schema: registration.schema, owned: registration.owned) }
  }

  /// Adds a client the addressables hosted here reach as a dependency, before the worker starts.
  public func provide<Client: Sendable>(_ client: Client) {
    precondition(!isStarted, "a worker takes its clients before it starts")
    dependencies.withLock { $0.register(client) }
  }

  func dependency<Client: Sendable>(_ type: Client.Type) -> Client {
    dependencies.withLock { $0.get(type) }
  }

  public var isStarted: Bool {
    hosts.withLock { $0.started }
  }

  /// Begins the scan. Until then a worker hosts only what it is called, attached or poked for: mail nobody poked it for waits in the store, and so does a job or a wake that is due.
  public func start() {
    let starts = hosts.withLock { hosts in
      hosts.started = true
      defer { hosts.scanning = true }
      return !hosts.scanning
    }
    if starts { scan() }
  }

  /// Mail from outside any addressable, durable when the call returns: `worker.send(id).deposit(42)`.
  public func send<C: Cell>(_ id: C.ID) -> C.Sender {
    C.sender(Reach(worker: self, writer: .outside).outbox(id.description))
  }

  public func send<J: Job>(_ message: J.Message, to id: J.ID) {
    Reach(worker: self, writer: .outside).outbox(id.description).post(message)
  }

  /// Writes the mail row at once; the outer store refusing it is a broken disk, so it traps.
  func post(_ envelope: Envelope) {
    do {
      try store.write { try $0.execute("INSERT INTO wuwei_mail (recipient, payload, lifecycle) VALUES (?, ?, ?)", .text(envelope.recipient), .blob(envelope.payload), envelope.lifecycle.map { .text($0.rawValue) } ?? .null) }
    } catch {
      preconditionFailure("could not send to \(envelope.recipient): \(error)")
    }
    poke(envelope.recipient)
  }

  public func create<Created: Job>(_ address: Address<Created>, params: Created.Params) throws {
    try store.write {
      try $0.execute("INSERT INTO wuwei_job (address, params) VALUES (?, ?) ON CONFLICT DO NOTHING", .text(address.description), .blob(encode(params)))
    }
    poke(address.description)
  }

  /// Whether mail waits for `recipient`: sent, and not yet taken by a step that committed.
  public func hasMail<Message>(for recipient: Recipient<Message>) -> Bool {
    do { return try store.read { try !$0.rows("SELECT 1 FROM wuwei_mail WHERE recipient = ? LIMIT 1", .text(recipient.raw)).isEmpty } }
    catch { preconditionFailure("could not read the mail of \(recipient.raw): \(error)") }
  }

  /// Whether `id` was ever created: running, hibernating or done.
  public func exists<J: Job>(_ id: J.ID) -> Bool {
    exists(id, reading: .span(ReadSpan(store)))
  }

  func exists<J: Job>(_ id: J.ID, reading: Reading) -> Bool {
    !reading.rows("SELECT 1 FROM wuwei_job WHERE address = ?", [.text(id.description)]).isEmpty
  }

  /// Closes the shared snapshot when the synchronous scope returns; reads through escaped handles trap.
  public func read<Value>(_ body: (Reader) throws -> Value) rethrows -> Value {
    Lane.preconditionNoRead()
    let span = ReadSpan(store)
    defer { span.close() }
    return try body(Reader(worker: self, span: span))
  }

  public func cell<C: Cell>(_ id: C.ID) -> C {
    cell(id, reading: .span(ReadSpan(store)))
  }

  func cell<C: Cell>(_ id: C.ID, reading: Reading) -> C {
    reading.prepare(C.self)
    return C(_context: CellContext(id: id, db: Database(access: .reading(reading, ReadTarget(id))), reach: Reach(worker: self, writer: .read(reading))))
  }

  public func job<J: Job>(_ id: J.ID) -> J {
    job(id, reading: .span(ReadSpan(store)))
  }

  func job<J: Job>(_ id: J.ID, reading: Reading) -> J {
    reading.prepare(J.self)
    return J(_context: JobContext(id: id, db: JobDatabase(access: .reading(reading, ReadTarget(id))), reach: Reach(worker: self, writer: .read(reading)), live: nil))
  }

  /// A call to a cell from outside any addressable: `body` runs on the cell's owner as one durable step, and its value comes back once that step is durable. What `body` throws rolls the step back and is thrown here. Nothing about a call is durable. A draining holder makes the call wait for a claim; a serving holder refuses it with `Evicted`, as does this worker quiescing or an incarnation dying: the step may have landed then, so what a caller repeats must be safe to repeat.
  public func call<C: Cell, Value: Sendable>(_ id: C.ID, _ body: @Sendable (inout C) throws -> Value) async throws -> Value {
    let address = id.description
    while true {
      guard let host = try await heldHost(address) else { throw Evicted(address: address) }
      let answer: Result<Value?, any Error> = await host.run { incarnation in
        do { return .success(try await incarnation.answer(C.self, body)) } catch { return .failure(error) }
      }
      if let value = try answer.get() { return value }
    }
  }

  /// The live host of an address here, waiting out a draining holder; `nil` when the address is not this worker's to host.
  private func heldHost(_ address: String) async throws(CancellationError) -> Host? {
    let host = try await held(address) { () -> Host?? in
      switch hosting(address) {
      case let .live(host): host
      case .unavailable: .some(nil)
      case .draining: nil
      }
    }
    return host ?? nil
  }

  /// The first value `settle` gives, asking again on every poke of `address` and every scan (only scans for `nil`); `nil` once this worker ends its holds or quiesces.
  private func held<Value>(_ address: String?, _ settle: () -> Value?) async throws(CancellationError) -> Value? {
    if let value = settle() { return value }
    let (stream, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    guard let (token, startsScan) = hosts.withLock({ hosts -> (UInt64, Bool)? in
      guard hosts.holding else { return nil }
      hosts.nextHold += 1
      hosts.holds[hosts.nextHold] = (address, wake)
      defer { hosts.scanning = true }
      return (hosts.nextHold, !hosts.scanning)
    }) else { return nil }
    defer {
      hosts.withLock { $0.holds[token] = nil }
      wake.finish()
    }
    if startsScan { scan() }
    var iterator = stream.makeAsyncIterator()
    while true {
      if Task.isCancelled { throw CancellationError() }
      if let value = settle() { return value }
      guard await iterator.next() != nil else {
        if Task.isCancelled { throw CancellationError() }
        return nil
      }
    }
  }

  /// Announces this worker as the successor of every worker created before it. One of those that runs this build marks its leases draining at its next scan and claims draining from then on, so that calls and sockets here wait for it instead of being refused, and it keeps serving what it holds until it quiesces. Returns once no other worker holds a lease that is not draining, or two scan intervals after the announcement: a holder that never answers is an older build or a dead process.
  public func takeOver() async {
    let announced = scheduler.now
    do {
      try store.write(label: "worker.takeOver") {
        try $0.execute(
          "INSERT INTO wuwei_successor (id, worker, announced_at) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET worker = excluded.worker, announced_at = excluded.announced_at",
          .text(id), .integer(announced.milliseconds),
        )
      }
    } catch {
      preconditionFailure("could not announce \(id) as the successor: \(error)")
    }
    defer { log.info("worker takeOver duration_ms=\((scheduler.now - announced).milliseconds)") }
    let deadline = announced + options.scanInterval * 2
    scheduler.at(deadline) { [self] in wakeHeldCalls() }
    _ = try? await held(nil) { () -> Void? in
      if scheduler.now >= deadline { return () }
      do {
        let serving = try store.read { try !$0.rows("SELECT 1 FROM wuwei_addressable WHERE expires_at > ? AND draining = 0 AND holder != ? LIMIT 1", .integer(scheduler.now.milliseconds), .text(id)).isEmpty }
        return serving ? nil : ()
      } catch {
        preconditionFailure("could not read the leases \(id) takes over: \(error)")
      }
    }
  }

  /// Takes a socket to a cell, waiting out a draining holder as a call does. `nil` when the cell is not this worker's to host: it lives elsewhere, or this worker does not register its kind, or quiesces. The cell hears `attached` first; `output` runs on the cell's lane, in order, and must not block.
  public func attach<S: Socket, C: Cell>(_ socket: S.Type, to id: C.ID, opening: S.Opening, output: @escaping @Sendable (SocketOutput<S>) -> Void) async throws(CancellationError) -> Peer<S>? {
    try await attach(socket, to: id.description, opening: opening, output: output)
  }

  public func attach<S: Socket, C: Cell>(_ socket: S.Type, to id: C.ID, output: @escaping @Sendable (SocketOutput<S>) -> Void) async throws(CancellationError) -> Peer<S>? where S.Opening == Void {
    try await attach(socket, to: id.description, opening: (), output: output)
  }

  /// Takes a socket to a job, which only publishes to it.
  public func attach<S: Socket, J: Job>(_ socket: S.Type, to id: J.ID, opening: S.Opening, output: @escaping @Sendable (SocketOutput<S>) -> Void) async throws(CancellationError) -> Peer<S>? where S.Incoming == Never {
    try await attach(socket, to: id.description, opening: opening, output: output)
  }

  public func attach<S: Socket, J: Job>(_ socket: S.Type, to id: J.ID, output: @escaping @Sendable (SocketOutput<S>) -> Void) async throws(CancellationError) -> Peer<S>? where S.Incoming == Never, S.Opening == Void {
    try await attach(socket, to: id.description, opening: (), output: output)
  }

  private func attach<S: Socket>(_ socket: S.Type, to address: String, opening: S.Opening, output: @escaping @Sendable (SocketOutput<S>) -> Void) async throws(CancellationError) -> Peer<S>? {
    guard try await heldHost(address) != nil else { return nil }
    let attachment = sockets.withLock { sockets in
      sockets.count += 1
      let attachment = Attachment(id: sockets.count, address: address, worker: self, socket, opening: opening, output: output)
      sockets.attached[address, default: []].append(attachment)
      return attachment
    }
    attachment.enqueue(.attached)
    return Peer(attachment: attachment)
  }

  func detach(_ attachment: Attachment) {
    sockets.withLock { sockets in
      sockets.attached[attachment.address]?.removeAll { $0 === attachment }
      if sockets.attached[attachment.address]?.isEmpty == true { sockets.attached[attachment.address] = nil }
    }
  }

  func attachments(at address: String) -> [Attachment] {
    sockets.withLock { $0.attached[address, default: []] }
  }

  /// Brings one socket event to whichever incarnation of its addressable lives here, waiting out one that is leaving. A socket whose addressable this worker can no longer host is ended.
  func deliver(_ inbound: Attachment.Inbound, from attachment: Attachment) async {
    while let host = host(attachment.address) {
      if await host.run({ await $0.socket(inbound, from: attachment) }) { return }
    }
    attachment.end()
  }

  /// Ends every call and attach waiting out a draining holder as refused, and refuses such a wait from now on, while what this worker hosts keeps serving. A server calls it as it stops taking requests, so that a waiting request answers before the drain ends it.
  public func endHolds() {
    hosts.withLock { $0.endHolds() }
  }

  public func quiesce() async {
    let task = hosts.withLock { hosts in
      if let task = hosts.quiescence { return task }
      let holding = scheduler.now
      store.holdLeases()
      log.info("worker quiesce step=holdLeases duration_ms=\((scheduler.now - holding).milliseconds)")
      hosts.claiming = false
      let draining = scheduler.now
      do {
        try store.write(label: "worker.draining") { try $0.execute("UPDATE wuwei_addressable SET draining = 1 WHERE holder = ? AND expires_at > ?", .text(id), .integer(scheduler.now.milliseconds)) }
      } catch {
        preconditionFailure("could not mark the leases of \(id) draining: \(error)")
      }
      log.info("worker quiesce step=draining duration_ms=\((scheduler.now - draining).milliseconds)")
      hosts.endHolds()
      let startsMaintenance = !hosts.scanning
      hosts.scanning = true
      let live = Array(hosts.live.values)
      let task = self.task { [self] in
        if startsMaintenance { scan() }
        for host in live {
          await host.quiesce()
        }
        for attachment in sockets.withLock({ $0.attached.values.flatMap(\.self) }) {
          attachment.end()
        }
        self.hosts.withLock { $0.quiesced = true }
      }
      hosts.quiescence = task
      return task
    }
    await task.value
  }

  var isQuiescing: Bool {
    hosts.withLock { !$0.claiming }
  }

  public func release() {
    precondition(hosts.withLock { $0.quiesced }, "a worker releases its leases only after quiescing")
    maintaining.withLock { maintaining in
      if !maintaining { return }
      do {
        try store.write(label: "worker.release") { try $0.execute("UPDATE wuwei_addressable SET expires_at = 0 WHERE holder = ?", .text(id)) }
      } catch {
        preconditionFailure("could not release the leases of \(id): \(error)")
      }
      maintaining = false
    }
  }

  /// What follows the commit of mail posted on the host program's own transaction (``Recipient/post(_:on:)``). It returns at once, so the host may call it from its commit hook, where the writer is still its own.
  public func poke<Message>(_ recipient: Recipient<Message>) {
    scheduler.post { [self] in poke(recipient.raw) }
  }

  /// Makes sure the addressable is alive here if it can be, and has it look at its mail. Lossy: if someone else holds it, nothing happens, and that worker's scan finds the mail.
  func poke(_ address: String) {
    wakeHeldCalls(at: address)
    if let host = host(address) { task { await host.pull() } }
  }

  private func wakeHeldCalls(at address: String? = nil) {
    let wakes = hosts.withLock { hosts in
      hosts.holds.values.filter { address == nil || $0.address == address }.map(\.wake)
    }
    for wake in wakes { wake.yield() }
  }

  /// The live host of an address here, claiming its lease if it is free.
  private func host(_ address: String) -> Host? {
    if case let .live(host) = hosting(address) { host } else { nil }
  }

  private func hosting(_ address: String) -> Hosting {
    guard let slash = address.firstIndex(of: "/"), let registration = registrations.withLock({ $0[String(address[..<slash])] }) else { return .unavailable }
    return hosts.withLock { hosts in
      guard hosts.claiming else { return .unavailable }
      if let live = hosts.live[address] { return .live(live) }
      do {
        switch try claim(address, key: String(address[address.index(after: slash)...]), isJob: registration.isJob) {
        case let .claimed(claim):
          let host = try registration.host(self, claim)
          hosts.live[address] = host
          return .live(host)
        case .draining: return .draining
        case .refused: return .unavailable
        }
      } catch {
        log.error("could not host \(address): \(error)")
        return .unavailable
      }
    }
  }

  func remove(_ host: Host, at address: String, repoke: Bool) {
    hosts.withLock { hosts in
      if hosts.live[address] === host { hosts.live[address] = nil }
    }
    if repoke { poke(address) }
  }

  func mail(for address: String) -> [Mail] {
    do {
      return try store.read { try $0.rows("SELECT id, payload, lifecycle FROM wuwei_mail WHERE recipient = ? ORDER BY id", .text(address)) }
        .map { Mail(id: $0["id"].integer!, payload: $0["payload"].blob!, lifecycle: $0["lifecycle"].text) }
    } catch {
      log.error("could not read the mail of \(address): \(error)")
      return []
    }
  }

  @discardableResult
  func task(_ operation: sending @escaping () async -> Void) -> Task<Void, Never> {
    Task(executorPreference: scheduler, operation: operation)
  }

  /// Takes a free or expired lease, or one this worker held before, bumping the fence so that no earlier holder, an earlier incarnation here included, can commit again. A worker with a successor claims draining; any other takes no lease of another's while another worker drains one, so that the outgoing worker keeps every address it reaches. Mail that reaches a finished job is dropped here.
  private func claim(_ address: String, key: String, isJob: Bool) throws -> Claimed {
    let now = scheduler.now
    return try store.write(label: "worker.claim") { db in
      var job: JobRow?
      if isJob {
        guard let row = try db.rows("SELECT phase, params, creator FROM wuwei_job WHERE address = ?", .text(address)).first else { return .refused }
        guard row["phase"].text != "done" else {
          try db.execute("DELETE FROM wuwei_mail WHERE recipient = ?", .text(address))
          return .refused
        }
        job = JobRow(phase: row["phase"].text!, params: row["params"].blob!, creator: row["creator"].text)
      }
      let lease = try db.rows("SELECT holder = ? AS mine, expires_at > ? AS live, draining FROM wuwei_addressable WHERE address = ?", .text(id), .integer(now.milliseconds), .text(address)).first
      let mine = lease?["mine"].integer == 1
      if let lease, !mine, lease["live"].integer == 1 { return lease["draining"].integer == 1 ? .draining : .refused }
      let handingOver = try !db.rows("SELECT 1 FROM wuwei_successor WHERE worker != ? AND announced_at >= ?", .text(id), .integer(born.milliseconds)).isEmpty
      if !mine, !handingOver, try !db.rows("SELECT 1 FROM wuwei_addressable WHERE draining = 1 AND expires_at > ? AND holder != ? LIMIT 1", .integer(now.milliseconds), .text(id)).isEmpty {
        return .draining
      }
      let row = try db.rows(
        """
        INSERT INTO wuwei_addressable (address, holder, fence, expires_at, draining) VALUES (?, ?, 1, ?, ?)
        ON CONFLICT (address) DO UPDATE SET holder = excluded.holder, fence = fence + 1, expires_at = excluded.expires_at, draining = excluded.draining
        RETURNING id, fence, page_count, wake_at
        """,
        .text(address), .text(id), .integer((now + options.leaseDuration).milliseconds), .integer(handingOver ? 1 : 0),
      )[0]
      return .claimed(Claim(
        key: key, lease: Lease(id: row["id"].integer!, fence: row["fence"].integer!), pageCount: UInt32(row["page_count"].integer!),
        wakeAt: row["wake_at"].integer.map(Instant.init(milliseconds:)), job: job,
      ))
    }
  }

  /// The backstop behind every poke: renews this worker's leases, marking them draining once it has a successor, then pokes every recipient with mail, every job nobody holds or whose wake time has come, and every cell whose wake time has come and that nobody else holds.
  private func scan() {
    let now = scheduler.now
    let again = maintaining.withLock { maintaining in
      guard maintaining else { return false }
      do {
        try store.write(label: "worker.scan.renewLeases") {
          try $0.execute(
            """
            UPDATE wuwei_addressable SET expires_at = ?1,
              draining = draining OR EXISTS (SELECT 1 FROM wuwei_successor WHERE worker != ?2 AND announced_at >= ?3)
            WHERE holder = ?2 AND expires_at > ?4
            """,
            .integer((now + options.leaseDuration).milliseconds), .text(id), .integer(born.milliseconds), .integer(now.milliseconds),
          )
        }
        wakeHeldCalls()
        guard hosts.withLock({ $0.claiming && $0.started }) else { return true }
        let due = try store.read { db in
          try db.rows("SELECT DISTINCT recipient AS address FROM wuwei_mail") + db.rows(
            """
            SELECT job.address FROM wuwei_job AS job LEFT JOIN wuwei_addressable AS lease ON lease.address = job.address
            WHERE job.phase != 'done'
              AND (lease.id IS NULL OR lease.expires_at <= ? OR (lease.holder = ? AND job.wake_at <= ?))
            """,
            .integer(now.milliseconds), .text(id), .integer(now.milliseconds),
          ) + db.rows(
            "SELECT address FROM wuwei_addressable WHERE wake_at <= ? AND (expires_at <= ? OR holder = ?)",
            .integer(now.milliseconds), .integer(now.milliseconds), .text(id),
          )
        }
        for row in due {
          poke(row["address"].text!)
        }
      } catch {
        log.error("scan failed: \(error)")
      }
      return true
    }
    if again { scheduler.at(now + options.scanInterval) { [self] in scan() } }
  }
}

private final class WriterWaitingLock<State: Sendable>: Sendable {
  private let state: Mutex<State>

  init(_ state: State) { self.state = Mutex(state) }

  func withLock<Result: Sendable>(_ body: (inout State) throws -> Result) rethrows -> Result {
    Lane.preconditionNoWriter()
    return try state.withLock { try body(&$0) }
  }
}
