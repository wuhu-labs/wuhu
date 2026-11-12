/// Makes a struct a ``Job``: the macro adds a private `ctx`, with `db` and `id` over it, `kind` (the type's name unless declared), when the job declares a `State` a private `state` over `ctx.state`, and `_attached` and `_closed` from its nonmutating `attached(_ socket: SocketHandle<S>)` and `closed(_ socket: SocketHandle<S>)` methods.
@attached(member, names: named(_context), named(ctx), named(db), named(id), named(state), named(init), named(kind), named(_attached), named(_closed))
@attached(extension, conformances: Addressable, Job)
public macro Job() = #externalMacro(module: "WuweiMacros", type: "JobMacro")

/// Long-lived, effectful work: a struct whose only stored property is its context. `create` runs once, in the job's first epoch; `hydrate` builds the in-memory `State` on every boot, so `start` never sees one half made; `start` is the long task, rerun from the top after every failover, so its progress is what it wrote to its database. What it returns decides what happens next. A nonmutating method is a read that anyone may call through `job(_:)` at the durable snapshot. Write one with ``Job()``.
public protocol Job: Addressable {
  associatedtype Params: Codable & Sendable
  associatedtype State = Void
  init(_context: JobContext<Self>)
  var _context: JobContext<Self> { get set }
  static func create(ctx: inout JobContext<Self>) throws
  static func hydrate(ctx: inout JobContext<Self>) throws -> State
  nonisolated(nonsending) mutating func start() async throws -> Outcome
  /// Greets a socket: once as it attaches, and once per incarnation, after `hydrate`, for every socket attached by then. It runs beside `start`, between its awaits, and sees `state`.
  func _attached(_ event: SocketEvent)
  /// Says goodbye to a socket it greeted and that then closed, once, while this incarnation lives. It runs beside `start`, between its awaits, and sees `state`.
  func _closed(_ event: SocketEvent)
}

extension Job {
  public static func create(ctx _: inout JobContext<Self>) throws {}

  public func _attached(_: SocketEvent) {}

  public func _closed(_: SocketEvent) {}
}

extension Job where State == Void {
  public static func hydrate(ctx _: inout JobContext<Self>) throws {}
}

public struct Outcome: Sendable {
  enum Kind: Sendable {
    case done(Envelope?)
    case notDone
    case hibernate(until: Instant?)
  }

  let kind: Kind

  /// The job is finished for good: its row stays as a tombstone, so creating it again does nothing.
  public static let done = Outcome(kind: .done(nil))
  /// Run `start` again after a delay; a throw from `start` means the same.
  public static let notDone = Outcome(kind: .notDone)
  /// Drop the instance and its state but keep the lease; mail, or `until`, brings it back through `hydrate` and `start`.
  public static let hibernate = Outcome(kind: .hibernate(until: nil))

  public static func hibernate(until instant: Instant) -> Outcome {
    Outcome(kind: .hibernate(until: instant))
  }

  /// Done, and the message commits in the same epoch as the end of the job.
  public static func done<Message>(sending message: Message, to recipient: Recipient<Message>) -> Outcome {
    Outcome(kind: .done(Envelope(recipient: recipient.raw, payload: encode(message))))
  }
}

/// What a job's code reaches. Not `Sendable`, so no child task can take it: a child gets ``effects`` and hands its result back, and only the job itself writes and takes mail. On a read handle there is only the database, and writing traps.
public struct JobContext<Target: Job> {
  public let id: Target.ID
  public var db: JobDatabase
  private let reach: Reach
  private let live: Live<Target>?

  init(id: Target.ID, db: JobDatabase, reach: Reach, live: Live<Target>?) {
    self.id = id
    self.db = db
    self.reach = reach
    self.live = live
  }

  public var params: Target.Params {
    running.params
  }

  /// What `hydrate` built.
  public var state: Target.State {
    get { running.state! }
    nonmutating set { running.state = newValue }
  }

  public var now: Instant {
    reach.worker.scheduler.now
  }

  public func dependency<Client: Sendable>(_ type: Client.Type) -> Client {
    reach.worker.dependency(type)
  }

  public func cell<Other: Cell>(_ id: Other.ID) -> Other {
    reach.worker.cell(id, within: reach.within)
  }

  public func job<Other: Job>(_ id: Other.ID) -> Other {
    reach.worker.job(id, within: reach.within)
  }

  /// Durable once the epoch open now is: the message leaves before any output that follows.
  public mutating func send<Other: Cell>(_ id: Other.ID) -> Other.Sender {
    Other.sender(reach.outbox(id.description))
  }

  public mutating func send<Message>(_ message: Message, to recipient: Recipient<Message>) {
    reach.outbox(recipient.raw).post(message)
  }

  public mutating func send<Other: Job>(_ message: Other.Message, to id: Other.ID) {
    reach.outbox(id.description).post(message)
  }

  /// Creates the job unless a job with that address already exists or existed: derive the address from something durable, so that a rerun creates nothing new.
  public mutating func create<Created: Job>(_ id: Created.ID, params: Created.Params) {
    reach.create(id, params: params)
  }

  /// The sockets of type `S` attached to this addressable on this worker, in the order they came.
  public func sockets<S: Socket>(of type: S.Type) -> [SocketHandle<S>] {
    reach.worker.attachments(at: id.description).filter { $0.socket == ObjectIdentifier(type) }.map { SocketHandle(attachment: $0, reach: reach) }
  }

  /// What a child task of `start` may use.
  public var effects: Effects {
    Effects(host: running.incarnation.host!, run: running.run, worker: reach.worker)
  }

  public func effect<Value>(_ body: () async throws -> Value) async throws -> Value {
    try await effects.effect(body)
  }

  /// The next message, or `nil` once `timeout` passes without one. Taking a message deletes its mail row in the epoch open now, so a crash before that commits delivers it again.
  public func receive(within timeout: Duration) async throws -> Target.Message? {
    let incarnation = running.incarnation
    let deadline = now + timeout
    while incarnation.inbox.isEmpty {
      guard now < deadline else { return nil }
      try await incarnation.park(until: deadline, wakesOnMail: true)
    }
    return try take()
  }

  /// Runs `body` as an effect in a child task, unless a message for which `stop` holds comes first: then `body` is cancelled and awaited, and that message is taken as `receive` takes it. Messages for which `stop` does not hold are taken and handed to `body` in `messages`. A cancelled `start` ends the wait for a message and takes no mail, not `race`: cancellation is not a message, so `race` then awaits `body` and returns what it gives, and what is queued stays for the start that runs next.
  public func race<Value: Sendable>(_ body: @escaping @Sendable (Effects, AsyncStream<Target.Message>) async throws -> Value, until stop: (Target.Message) -> Bool, isolation: isolated (any Actor)? = #isolation) async throws -> Raced<Value, Target.Message> where Target.Message: Sendable {
    let (messages, others) = AsyncStream<Target.Message>.makeStream()
    defer { others.finish() }
    if !Task.isCancelled, let message = try take(until: stop, others: others) { return .message(message) }
    let effects = effects
    return try await withThrowingTaskGroup(of: Value?.self) { group in
      // Without this capture the group's body, which takes mail, runs off the lane: swift#87503.
      _ = isolation
      group.addTask { try await effects.effect { try await body(effects, messages) } }
      group.addTask {
        try await effects.waitForMail()
        return nil
      }
      defer { group.cancelAll() }
      while true {
        if let finished = try await group.next()! { return .finished(finished) }
        guard !Task.isCancelled else { continue }
        if let message = try take(until: stop, others: others) { return .message(message) }
        group.addTask {
          try await effects.waitForMail()
          return nil
        }
      }
    }
  }

  private func take(until stop: (Target.Message) -> Bool, others: AsyncStream<Target.Message>.Continuation) throws -> Target.Message? {
    while !running.incarnation.inbox.isEmpty {
      let message = try take()
      if stop(message) { return message }
      others.yield(message)
    }
    return nil
  }

  private func take() throws -> Target.Message {
    let incarnation = running.incarnation
    let mail = incarnation.inbox.removeFirst()
    incarnation.record(.consume(mail: mail.id))
    return try decode(Target.Message.self, from: mail.payload)
  }

  public func sleep(for duration: Duration) async throws {
    let deadline = now + duration
    while now < deadline {
      try await running.incarnation.park(until: deadline, wakesOnMail: false)
    }
  }

  private var running: Live<Target> {
    guard let live else { preconditionFailure("\(id) is a read handle: it has only its database") }
    return live
  }
}

public enum Raced<Value, Message> {
  case finished(Value)
  case message(Message)
}

/// What a live job holds beyond its database, shared by every copy of its context.
final class Live<Target: Job> {
  let incarnation: Incarnation
  let params: Target.Params
  var state: Target.State?
  var run: UInt64 = 0
  private var greeted: Set<Int> = []

  init(incarnation: Incarnation, params: Target.Params) {
    self.incarnation = incarnation
    self.params = params
  }

  var context: JobContext<Target> {
    JobContext(id: Target.ID(incarnation.key), db: JobDatabase(access: .live(incarnation)), reach: reach, live: self)
  }

  private var reach: Reach {
    Reach(worker: incarnation.worker, writer: .incarnation(incarnation))
  }

  func greet(_ attachment: Attachment) {
    guard greeted.insert(attachment.id).inserted else { return }
    Target(_context: context)._attached(SocketEvent(kind: .attached, attachment: attachment, reach: reach))
  }

  func close(_ attachment: Attachment) {
    guard greeted.remove(attachment.id) != nil else { return }
    Target(_context: context)._closed(SocketEvent(kind: .closed, attachment: attachment, reach: reach))
  }
}

/// The part of a job that a child task of its `start` may hold. Every effect waits until everything the job wrote before it is durable, and traps when used from a task the runtime did not start or after the `start` it came from returned.
public struct Effects: Sendable {
  let host: Host
  let run: UInt64
  let worker: Worker

  /// Waits for the job's next mail; cancellation ends the wait and is no outcome of its own.
  fileprivate func waitForMail() async throws {
    do { try await host.mail() } catch is CancellationError {}
  }

  public var now: Instant {
    worker.scheduler.now
  }

  public func dependency<Client: Sendable>(_ type: Client.Type) -> Client {
    worker.dependency(type)
  }

  public func effect<Value>(_ body: () async throws -> Value) async throws -> Value {
    let scheduler = worker.scheduler.asUnownedTaskExecutor()
    precondition(withUnsafeCurrentTask { $0?.unownedTaskExecutor == scheduler }, "effects used from a task the runtime did not start")
    try await host.gate(run: run)
    return try await body()
  }
}

struct JobRow: Sendable {
  let phase: String
  let params: [UInt8]
}

extension Lifecycle {
  static func job<J: Job>(_: J.Type, row: JobRow) -> Lifecycle {
    Lifecycle(boot: { incarnation in
      incarnation.startTask = incarnation.hop { await $0.runJob(J.self, row) }
    }, deliver: { incarnation, mail in
      incarnation.inbox.append(mail)
      incarnation.wakeForMail()
    }, socket: { incarnation, attachment, inbound in
      guard let live = incarnation.liveJob as? Live<J> else { return }
      switch inbound {
      case .attached: live.greet(attachment)
      case .closed: live.close(attachment)
      case .frame: preconditionFailure("a job's socket takes no frames")
      }
    })
  }
}

extension Incarnation {
  fileprivate func runJob<J: Job>(_: J.Type, _ row: JobRow) async {
    var job: J
    let live: Live<J>
    do {
      live = try Live(incarnation: self, params: decode(J.Params.self, from: row.params))
      var ctx = live.context
      if row.phase == "new" {
        try step {
          try J.create(ctx: &ctx)
          record(.created)
        }
      }
      live.state = try step { try J.hydrate(ctx: &ctx) }
      job = J(_context: ctx)
    } catch {
      worker.log.error("\(address) failed to boot: \(error)")
      if !dead { retire(.released) }
      return
    }
    liveJob = live
    for attachment in worker.attachments(at: address) {
      live.greet(attachment)
    }
    var runs: UInt64 = 0
    while !dead, !retiring, !Task.isCancelled {
      runs += 1
      running = runs
      live.run = runs
      let outcome: Outcome
      do {
        outcome = try await job.start()
      } catch {
        if !dead, !Task.isCancelled { worker.log.error("\(address) failed to start: \(error)") }
        outcome = .notDone
      }
      running = nil
      guard !dead else { return }
      switch outcome.kind {
      case let .done(last):
        if let last { record(.send(last)) }
        retire(.finished)
        for attachment in worker.attachments(at: address) {
          output(.close(attachment))
        }
      case let .hibernate(until):
        retire(.hibernated(until: until))
      case .notDone:
        guard !Task.isCancelled else { return }
        try? await job._context.sleep(for: worker.options.retryDelay)
      }
    }
  }
}
