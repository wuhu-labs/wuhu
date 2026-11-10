import GRDBSQLite
import Logging
import Synchronization

/// The addressable types a worker can host.
public struct Registration: Sendable {
  let kind: String
  let isJob: Bool
  let schema: [String]
  let lifecycle: @Sendable (Claim) -> Lifecycle

  public static func cell<C: Cell>(_: C.Type) -> Registration {
    Registration(kind: C.kind, isJob: false, schema: C.schema) { _ in .cell(C.self) }
  }

  public static func job<J: Job>(_: J.Type) -> Registration {
    Registration(kind: J.kind, isJob: true, schema: J.schema) { .job(J.self, row: $0.job!) }
  }

  func host(_ worker: Worker, _ claim: Claim) throws -> Host {
    try Host(
      Incarnation(
        address: "\(kind)/\(claim.key)", key: claim.key, lease: claim.lease, pageCount: claim.pageCount, wakeAt: claim.wakeAt,
        worker: worker, schema: schema, lifecycle: lifecycle(claim),
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

  private struct Hosts {
    var live: [String: Host] = [:]
    var claiming = true
    var started = false
  }

  private struct Sockets {
    var attached: [String: [Attachment]] = [:]
    var count = 0
  }

  public let id: String
  public let scheduler: any Scheduler
  let store: OuterStore
  let shipper: Shipper
  let options: Options
  let log = Logger(label: "wuwei")
  private let registrations = Mutex<[String: Registration]>([:])
  private let dependencies: Mutex<Dependencies>
  private let hosts = Mutex(Hosts())
  private let sockets = Mutex(Sockets())

  public init(id: String, storage: Storage, scheduler: any Scheduler, registrations: [Registration] = [], dependencies: Dependencies = Dependencies(), options: Options = Options()) {
    self.id = id
    self.scheduler = scheduler
    self.dependencies = Mutex(dependencies)
    self.options = options
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
    if store.file == nil { store.prepare(kind: registration.kind, schema: registration.schema) }
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
      defer { hosts.started = true }
      return !hosts.started
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
      try store.write { try $0.execute("INSERT INTO wuwei_mail (recipient, payload) VALUES (?, ?)", .text(envelope.recipient), .blob(envelope.payload)) }
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
    exists(id, within: nil)
  }

  func exists<J: Job>(_ id: J.ID, within incarnation: Incarnation?) -> Bool {
    let sql = "SELECT 1 FROM wuwei_job WHERE address = ?"
    if let rows = incarnation?.readOpen(as: id.key, sql, [.text(id.description)]) { return !rows.isEmpty }
    do { return try store.read { try !$0.rows(sql, .text(id.description)).isEmpty } } catch { preconditionFailure("could not read \(id): \(error)") }
  }

  /// A read handle: the cell's durable state. Layered, it reads one snapshot of the outer store, held for as long as the handle lives, and what the cell's open epoch holds is not there yet. Shared, every read is a fresh one.
  public func cell<C: Cell>(_ id: C.ID) -> C {
    cell(id, within: nil)
  }

  func cell<C: Cell>(_ id: C.ID, within incarnation: Incarnation?) -> C {
    C(_context: CellContext(id: id, db: Database(access: reading(id, within: incarnation)), reach: Reach(worker: self, writer: .none)))
  }

  /// A read handle on a job, as ``cell(_:)`` is on a cell. It has the job's database only: no params, no in-memory state.
  public func job<J: Job>(_ id: J.ID) -> J {
    job(id, within: nil)
  }

  func job<J: Job>(_ id: J.ID, within incarnation: Incarnation?) -> J {
    J(_context: JobContext(id: id, db: JobDatabase(access: reading(id, within: incarnation)), reach: Reach(worker: self, writer: .none), live: nil))
  }

  /// Layered, an addressable's durable database at one snapshot, its schema applied to this copy alone, so an addressable that never booted reads as a fresh one.
  private func reading<Target: Addressable>(_ address: Address<Target>, within incarnation: Incarnation?) -> Access {
    guard let file = store.file else {
      store.prepare(kind: Target.kind, schema: Target.schema)
      return .shared(store, owner: address.key, within: incarnation)
    }
    do {
      let outer = try Connection(path: file.path, flags: SQLITE_OPEN_READONLY)
      try outer.execute("BEGIN")
      let row = try outer.rows("SELECT id, page_count FROM wuwei_addressable WHERE address = ?", .text(address.description)).first
      let id = row?["id"].integer ?? 0
      let pages = PageFile(pageCount: UInt32(row?["page_count"].integer ?? 0), writable: true) { try outer.page(id, $0) }
      let db = try Connection(file: pages, owner: address.key)
      migrate(db, Target.schema)
      return .copy(db)
    } catch {
      preconditionFailure("could not read \(address): \(error)")
    }
  }

  /// A call to a cell from outside any addressable: `body` runs on the cell's owner as one durable step, and its value comes back once that step is durable. What `body` throws rolls the step back and is thrown here. Nothing about a call is durable. It throws `Evicted` when the cell is not this worker's to host or its incarnation died first: the step may have landed then, so what a caller repeats must be safe to repeat.
  public func call<C: Cell, Value: Sendable>(_ id: C.ID, _ body: @Sendable (inout C) throws -> Value) async throws -> Value {
    let address = id.description
    while let host = host(address) {
      let answer: Result<Value?, any Error> = await host.run { incarnation in
        do { return .success(try await incarnation.answer(C.self, body)) } catch { return .failure(error) }
      }
      if let value = try answer.get() { return value }
    }
    throw Evicted(address: address)
  }

  /// Takes a socket to a cell. `nil` when the cell is not this worker's to host: it lives elsewhere, or this worker does not register its kind. The cell hears `attached` first; `output` runs on the cell's lane, in order, and must not block.
  public func attach<S: Socket, C: Cell>(_ socket: S.Type, to id: C.ID, output: @escaping @Sendable (SocketOutput<S>) -> Void) -> Peer<S>? {
    attach(socket, to: id.description, output: output)
  }

  /// Takes a socket to a job, which only publishes to it.
  public func attach<S: Socket, J: Job>(_ socket: S.Type, to id: J.ID, output: @escaping @Sendable (SocketOutput<S>) -> Void) -> Peer<S>? where S.Incoming == Never {
    attach(socket, to: id.description, output: output)
  }

  private func attach<S: Socket>(_ socket: S.Type, to address: String, output: @escaping @Sendable (SocketOutput<S>) -> Void) -> Peer<S>? {
    guard host(address) != nil else { return nil }
    let attachment = sockets.withLock { sockets in
      sockets.count += 1
      let attachment = Attachment(id: sockets.count, address: address, worker: self, socket, output: output)
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

  /// Stops claiming, ends every job's `start`, waits for what the hosts wrote, gives up every lease so another worker can take over at once, and ends every socket.
  public func drain() async {
    let live = hosts.withLock { hosts in
      hosts.claiming = false
      return Array(hosts.live.values)
    }
    for host in live {
      await host.drain()
    }
    do {
      try store.write { try $0.execute("UPDATE wuwei_addressable SET expires_at = 0 WHERE holder = ?", .text(id)) }
    } catch {
      log.error("drain could not release the leases of \(id): \(error)")
    }
    for attachment in sockets.withLock({ $0.attached.values.flatMap(\.self) }) {
      attachment.end()
    }
  }

  /// What follows the commit of mail posted on the host program's own transaction (``Recipient/post(_:on:)``). It returns at once, so the host may call it from its commit hook, where the writer is still its own.
  public func poke<Message>(_ recipient: Recipient<Message>) {
    scheduler.post { [self] in poke(recipient.raw) }
  }

  /// Makes sure the addressable is alive here if it can be, and has it look at its mail. Lossy: if someone else holds it, nothing happens, and that worker's scan finds the mail.
  func poke(_ address: String) {
    if let host = host(address) { task { await host.pull() } }
  }

  /// The live host of an address here, claiming its lease if it is free.
  private func host(_ address: String) -> Host? {
    guard let slash = address.firstIndex(of: "/"), let registration = registrations.withLock({ $0[String(address[..<slash])] }) else { return nil }
    return hosts.withLock { hosts in
      if let live = hosts.live[address] { return live }
      guard hosts.claiming else { return nil }
      do {
        guard let claim = try claim(address, key: String(address[address.index(after: slash)...]), isJob: registration.isJob) else { return nil }
        let host = try registration.host(self, claim)
        hosts.live[address] = host
        return host
      } catch {
        log.error("could not host \(address): \(error)")
        return nil
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
      return try store.read { try $0.rows("SELECT id, payload FROM wuwei_mail WHERE recipient = ? ORDER BY id", .text(address)) }
        .map { Mail(id: $0["id"].integer!, payload: $0["payload"].blob!) }
    } catch {
      log.error("could not read the mail of \(address): \(error)")
      return []
    }
  }

  @discardableResult
  func task(_ operation: sending @escaping () async -> Void) -> Task<Void, Never> {
    Task(executorPreference: scheduler, operation: operation)
  }

  /// Takes a free or expired lease, or one this worker held before, bumping the fence so that no earlier holder, an earlier incarnation here included, can commit again. Mail that reaches a finished job is dropped here.
  private func claim(_ address: String, key: String, isJob: Bool) throws -> Claim? {
    let now = scheduler.now
    return try store.write { db in
      var job: JobRow?
      if isJob {
        guard let row = try db.rows("SELECT phase, params FROM wuwei_job WHERE address = ?", .text(address)).first else { return nil }
        guard row["phase"].text != "done" else {
          try db.execute("DELETE FROM wuwei_mail WHERE recipient = ?", .text(address))
          return nil
        }
        job = JobRow(phase: row["phase"].text!, params: row["params"].blob!)
      }
      let claimed = try db.rows(
        """
        INSERT INTO wuwei_addressable (address, holder, fence, expires_at) VALUES (?, ?, 1, ?)
        ON CONFLICT (address) DO UPDATE SET holder = excluded.holder, fence = fence + 1, expires_at = excluded.expires_at
        WHERE expires_at <= ? OR holder = excluded.holder
        RETURNING id, fence, page_count, wake_at
        """,
        .text(address), .text(id), .integer((now + options.leaseDuration).milliseconds), .integer(now.milliseconds),
      )
      guard let row = claimed.first else { return nil }
      return Claim(
        key: key, lease: Lease(id: row["id"].integer!, fence: row["fence"].integer!), pageCount: UInt32(row["page_count"].integer!),
        wakeAt: row["wake_at"].integer.map(Instant.init(milliseconds:)), job: job,
      )
    }
  }

  /// The backstop behind every poke: renews this worker's leases, then pokes every recipient with mail, every job nobody holds or whose wake time has come, and every cell whose wake time has come and that nobody else holds.
  private func scan() {
    guard hosts.withLock({ $0.claiming && $0.started }) else { return }
    let now = scheduler.now
    do {
      try store.write {
        try $0.execute(
          "UPDATE wuwei_addressable SET expires_at = ? WHERE holder = ? AND expires_at > ?",
          .integer((now + options.leaseDuration).milliseconds), .text(id), .integer(now.milliseconds),
        )
      }
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
    scheduler.at(now + options.scanInterval) { [self] in scan() }
  }
}
