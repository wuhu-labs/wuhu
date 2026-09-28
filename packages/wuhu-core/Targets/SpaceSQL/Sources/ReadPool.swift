import Dispatch
import GRDB
import GRDBSQLite
import Synchronization

/// Lazily opened read connections to one space file. A statement steps on its
/// connection's own queue, never on the cooperative pool, and a cancelled
/// caller interrupts it.
public final class ReadPool: Sendable {
  private let slots: [ReadSlot]
  private let load: Mutex<[Int]>

  public init(
    path: String,
    capacity: Int = 4,
    catalog: ViewCatalog = .identity,
    trace: (@Sendable (String) -> Void)? = nil,
  ) {
    slots = (0 ..< capacity).map { index in
      ReadSlot(path: path, catalog: catalog, trace: trace, label: "wuhu.space.read.\(index)")
    }
    load = Mutex(Array(repeating: 0, count: capacity))
  }

  public func run(
    _ sql: String,
    arguments: [DatabaseValue] = [],
    byteLimit: Int? = nil,
    scope: ReadScope,
  ) async throws -> (ReadRows, ReadTables) {
    try await withSlot { slot, token in
      try await slot.run(sql, arguments: arguments, byteLimit: byteLimit, scope: scope, token: token)
    }
  }

  /// The base tables `sql` reads, after the same verdicts `run` gives.
  public func tables(_ sql: String, scope: ReadScope) async throws -> ReadTables {
    try await withSlot { slot, token in
      try await slot.tables(sql, scope: scope, token: token)
    }
  }

  private func withSlot<T: Sendable>(_ body: (ReadSlot, UInt64) async throws -> T) async throws -> T {
    let index = load.withLock { load in
      let index = load.indices.min { load[$0] < load[$1] }!
      load[index] += 1
      return index
    }
    defer { load.withLock { $0[index] -= 1 } }
    let slot = slots[index]
    let token = nextToken.add(1, ordering: .relaxed).newValue
    return try await withTaskCancellationHandler {
      try await body(slot, token)
    } onCancel: {
      slot.latch.interrupt(token)
    }
  }
}

private let nextToken = Atomic<UInt64>(0)

actor ReadSlot {
  let latch = InterruptLatch()
  private let executor: QueueExecutor
  private let path: String
  private let catalog: ViewCatalog
  private let trace: (@Sendable (String) -> Void)?
  private var connection: ReadConnection?

  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

  init(path: String, catalog: ViewCatalog, trace: (@Sendable (String) -> Void)?, label: String) {
    self.executor = QueueExecutor(label: label)
    self.path = path
    self.catalog = catalog
    self.trace = trace
  }

  func run(
    _ sql: String,
    arguments: [DatabaseValue],
    byteLimit: Int?,
    scope: ReadScope,
    token: UInt64,
  ) throws -> (ReadRows, ReadTables) {
    try interruptible(token) { try $0.run(sql, arguments: arguments, byteLimit: byteLimit, scope: scope) }
  }

  func tables(_ sql: String, scope: ReadScope, token: UInt64) throws -> ReadTables {
    try interruptible(token) { try $0.tables(sql, scope: scope) }
  }

  private func interruptible<T>(_ token: UInt64, _ body: (ReadConnection) throws -> T) throws -> T {
    let connection = try open()
    latch.arm(token, connection.handle)
    defer { latch.disarm() }
    try Task.checkCancellation()
    do {
      return try body(connection)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT && Task.isCancelled {
      throw CancellationError()
    }
  }

  private func open() throws -> ReadConnection {
    if let connection { return connection }
    let opened = try ReadConnection(path: path, catalog: catalog, trace: trace)
    connection = opened
    return opened
  }
}

/// Interrupts the statement of one checkout only: a token that no longer
/// holds the connection interrupts nothing.
final class InterruptLatch: Sendable {
  private let armed = Mutex<(token: UInt64, handle: Int)?>(nil)

  func arm(_ token: UInt64, _ handle: OpaquePointer) {
    let address = Int(bitPattern: handle)
    armed.withLock { $0 = (token, address) }
  }

  func disarm() {
    armed.withLock { $0 = nil }
  }

  func interrupt(_ token: UInt64) {
    armed.withLock { armed in
      if let armed, armed.token == token { sqlite3_interrupt(OpaquePointer(bitPattern: armed.handle)) }
    }
  }
}

final class QueueExecutor: SerialExecutor {
  private let queue: DispatchQueue

  init(label: String) {
    queue = DispatchQueue(label: label)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedSerialExecutor()
    queue.async { job.runSynchronously(on: executor) }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}
