/// Makes a struct a ``Cell``: every mutating method that is not private and returns nothing becomes a message, and the macro adds a private `ctx`, with `db` and `id` over it, `kind` (the type's name unless declared), `Message` (`Never` for a cell that only reads), `receive` and the `Sender` behind `ctx.send(id)`. A message method is synchronous; it may throw.
@attached(member, names: named(_context), named(ctx), named(db), named(id), named(init), named(kind), named(Message), named(receive), named(Sender), named(sender), named(_socket))
@attached(extension, conformances: Addressable, Cell)
public macro Cell() = #externalMacro(module: "WuweiMacros", type: "CellMacro")

/// A durable state machine: a struct whose only stored property is its context. A nonmutating method is a read, which anyone may call through `cell(_:)` at the durable snapshot; a mutating method is a write, run only by the cell's owner and reached by mail, or, from outside any addressable, by `Worker.call`, which alone hears what it returns. A delivery is one synchronous call and one durable step: if `receive` throws, everything the call wrote, sent and emitted is rolled back, and the mail is still consumed. Write one with ``Cell()``.
public protocol Cell: Addressable {
  associatedtype Sender
  init(_context: CellContext<Self>)
  var _context: CellContext<Self> { get set }
  mutating func receive(_ message: Message) throws
  static func sender(_ outbox: Outbox<Message>) -> Sender
  mutating func _socket(_ event: SocketEvent) throws
  /// When the cell wants `wake()`, derived from its own tables: the runtime reads it at the end of every call, in the call's step, and never stores an alarm of its own. A wake must move it past the time it ran.
  func nextWake() -> Instant?
  /// One durable step, like a message, run once `nextWake()` has come.
  mutating func wake() throws
}

extension Cell {
  public mutating func _socket(_ event: SocketEvent) throws {
    event.unhandled()
  }

  public func nextWake() -> Instant? {
    nil
  }

  public mutating func wake() throws {}
}

/// What a cell's code reaches: its database, mail, best-effort outputs, read handles and time. The writes go to the owner's incarnation; a read handle has none, and writing through one traps.
public struct CellContext<Target: Cell> {
  public let id: Target.ID
  public var db: Database
  private let reach: Reach

  init(id: Target.ID, db: Database, reach: Reach) {
    self.id = id
    self.db = db
    self.reach = reach
  }

  public var now: Instant {
    reach.worker.scheduler.now
  }

  public func dependency<Client: Sendable>(_ type: Client.Type) -> Client {
    reach.worker.dependency(type)
  }

  /// Another cell's durable state, at one snapshot of the outer store. It lags that cell by its open epoch.
  public func cell<Other: Cell>(_ id: Other.ID) -> Other {
    reach.worker.cell(id, within: reach.within)
  }

  public func job<Other: Job>(_ id: Other.ID) -> Other {
    reach.worker.job(id, within: reach.within)
  }

  /// Whether the job was ever created, at the durable snapshot: one this call creates is not there yet.
  public func exists<Other: Job>(_ id: Other.ID) -> Bool {
    reach.worker.exists(id, within: reach.within)
  }

  /// Mail to another cell, durable once this call's epoch is: `ctx.send(id).deposit(42)`.
  public mutating func send<Other: Cell>(_ id: Other.ID) -> Other.Sender {
    Other.sender(reach.outbox(id.description))
  }

  public mutating func send<Message>(_ message: Message, to recipient: Recipient<Message>) {
    reach.outbox(recipient.raw).post(message)
  }

  public mutating func send<Other: Job>(_ message: Other.Message, to id: Other.ID) {
    reach.outbox(id.description).post(message)
  }

  /// Creates the job unless a job with that address already exists or existed.
  public mutating func create<Created: Job>(_ id: Created.ID, params: Created.Params) {
    reach.create(id, params: params)
  }

  /// A best-effort output: it runs once everything this call wrote is durable, and is lost if the process dies first.
  public mutating func emit(_ output: @escaping @Sendable () async -> Void) {
    reach.incarnation.output(.emit(output))
  }

  /// The sockets of type `S` attached to this addressable on this worker, in the order they came.
  public func sockets<S: Socket>(of type: S.Type) -> [SocketHandle<S>] {
    reach.worker.attachments(at: id.description).filter { $0.socket == ObjectIdentifier(type) }.map { SocketHandle(attachment: $0, reach: reach) }
  }
}

/// Where a message goes and how: staged in an incarnation's open epoch, or written at once from outside any addressable.
public struct Outbox<Message: Codable & Sendable> {
  let recipient: String
  let reach: Reach

  public func post(_ message: Message) {
    reach.post(Envelope(recipient: recipient, payload: encode(message)))
  }
}

/// What both contexts share: the worker, and who writes. An incarnation stages its writes in its open epoch; a sender outside any addressable writes at once; a read handle cannot write.
struct Reach {
  enum Writer {
    case incarnation(Incarnation)
    case outside
    case none
  }

  let worker: Worker
  let writer: Writer

  var incarnation: Incarnation {
    guard case let .incarnation(incarnation) = writer else { preconditionFailure("a read handle cannot write") }
    return incarnation
  }

  /// The incarnation whose step reads run in, if this is one.
  var within: Incarnation? {
    if case let .incarnation(incarnation) = writer { incarnation } else { nil }
  }

  func outbox<Message>(_ recipient: String) -> Outbox<Message> {
    Outbox(recipient: recipient, reach: self)
  }

  func post(_ envelope: Envelope) {
    switch writer {
    case let .incarnation(incarnation): incarnation.record(.send(envelope))
    case .outside: worker.post(envelope)
    case .none: preconditionFailure("a read handle cannot write")
    }
  }

  func create<Created: Job>(_ id: Created.ID, params: Created.Params) {
    incarnation.record(.create(job: id.description, params: encode(params)))
  }
}

extension Lifecycle {
  static func cell<C: Cell>(_: C.Type) -> Lifecycle {
    Lifecycle(boot: { incarnation in
      incarnation.armIdle()
      incarnation.armWake(C.self, at: incarnation.wakeAt)
    }, deliver: { incarnation, mail in
      incarnation.record(.consume(mail: mail.id))
      incarnation.call(C.self) { cell, _ in try cell.receive(decode(C.Message.self, from: mail.payload)) }
    }, socket: { incarnation, attachment, inbound in
      incarnation.call(C.self) { cell, reach in
        let kind: SocketEvent.Kind = switch inbound {
        case .attached: .attached
        case let .frame(frame): .frame(frame)
        case .closed: .closed
        }
        try cell._socket(SocketEvent(kind: kind, attachment: attachment, reach: reach))
      }
    })
  }
}

extension Incarnation {
  /// One call of a cell's owner: one durable step, which ends by reading the cell's `nextWake()` and recording it, when it moved, for the scan to find. `woke` is when a wake began: still being due at its end is a bug in the cell.
  @discardableResult
  fileprivate func call<C: Cell>(_: C.Type, woke: Instant? = nil, _ body: (inout C, Reach) throws -> Void) -> Bool {
    var next: Instant?
    let committed = atomically {
      let reach = Reach(worker: worker, writer: .incarnation(self))
      var cell = C(_context: CellContext(id: C.ID(key), db: Database(access: .live(self)), reach: reach))
      try body(&cell, reach)
      next = cell.nextWake()
      if let woke, let due = next { precondition(due > woke, "\(address) is still due after its wake") }
      if next != wakeAt { record(.wakes(at: next)) }
    }
    armIdle()
    if committed, next != wakeAt {
      wakeAt = next
      armWake(C.self, at: next)
    }
    return committed
  }

  /// A call from outside any addressable, answered once its step is durable. `nil` means this incarnation is gone or leaving.
  func answer<C: Cell, Value>(_: C.Type, _ body: (inout C) throws -> Value) async throws -> Value? {
    guard await admit() else { return nil }
    var result: Result<Value, any Error>?
    call(C.self) { cell, _ in
      result = Result { try body(&cell) }
      _ = try result!.get()
    }
    guard let value = try result?.get() else { throw Evicted(address: address) }
    try await gate()
    return value
  }

  /// Arms the in-process timer at the recorded wake time; at boot, one that passed while nobody held the cell wakes it at once.
  fileprivate func armWake<C: Cell>(_: C.Type, at next: Instant?) {
    wakeGeneration += 1
    guard let next, !dead else { return }
    let generation = wakeGeneration
    let hop = hop
    worker.scheduler.at(next) {
      hop { $0.wake(C.self, generation) }
    }
  }

  /// A wake that rolls back is tried again after `retryDelay`.
  private func wake<C: Cell>(_: C.Type, _ generation: Int) {
    guard generation == wakeGeneration, !dead, !retiring else { return }
    let now = worker.scheduler.now
    if !call(C.self, woke: now, { cell, _ in try cell.wake() }) {
      armWake(C.self, at: wakeAt.map { max($0, now + worker.options.retryDelay) })
    }
  }
}

extension Incarnation {
  func armIdle() {
    idleGeneration += 1
    let generation = idleGeneration
    let hop = hop
    worker.scheduler.at(worker.scheduler.now + worker.options.cellIdle) {
      hop { $0.evictIfIdle(generation) }
    }
  }

  private func evictIfIdle(_ generation: Int) {
    if generation == idleGeneration, !dead, !retiring { retire(.released) }
  }
}
