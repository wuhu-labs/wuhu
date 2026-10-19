#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import SessionDomain
import Synchronization
import TaskLifetime

/// How a job rejoins its exec after a server restart, kept in its row.
struct ExecJobSpec: Codable {
  var start: ExecStart
  var machine: String
  var lifetime: Double
  var defaultLifetime: Bool
}

/// The exec jobs this owner holds: one per exec tool call, from the call
/// until the exec's end is recorded, whether the call still waits on it or
/// has already returned `running`. They live in this process; the store's
/// job rows are what a restart re-adopts.
public final class ExecJobs: Sendable {
  struct Key: Hashable {
    let session: SessionID
    let call: ToolCallID
  }

  private let jobs = Mutex<[Key: ExecJob]>([:])
  /// Owns exec transport through terminal acknowledgement and teardown, even after settlement removes the job.
  let drivers = TaskScope()

  public init() {}

  func job(_ session: SessionID, _ call: ToolCallID) -> ExecJob? {
    jobs.withLock { $0[Key(session: session, call: call)] }
  }

  func job(_ session: SessionID, exec id: ExecID) -> ExecJob? {
    jobs.withLock { $0.values.first { $0.session == session && $0.id == id } }
  }

  func insert(_ job: ExecJob) {
    jobs.withLock { $0[Key(session: job.session, call: job.call)] = job }
  }

  func remove(_ job: ExecJob) {
    jobs.withLock { jobs in
      let key = Key(session: job.session, call: job.call)
      if jobs[key] === job { jobs.removeValue(forKey: key) }
    }
  }

  func finish(_ job: ExecJob, _ outcome: ExecJob.Outcome) {
    remove(job)
    job.ended.fulfill(outcome)
  }

  /// The cancel ids of `session`'s exec jobs whose call already returned.
  public func running(of session: SessionID) -> [String] {
    jobs.withLock { $0.values.filter { $0.session == session && $0.phase == .detached }.map(\.handle) }.sorted()
  }

  /// `session`'s jobs, to cancel them all at once, as archive does.
  func jobs(of session: SessionID) -> [ExecJob] {
    jobs.withLock { $0.values.filter { $0.session == session } }
  }
}

final class ExecJob: Sendable {
  enum Phase: Sendable {
    /// The tool call still waits: the end becomes its result.
    case awaited
    /// The call returned `running`: the end becomes one message.
    case detached
    /// Cancelled or archived: the end is not announced.
    case cancelled
  }

  enum Outcome: Sendable {
    case payload(ToolResultPayload)
    case problem(ToolProblem)
  }

  let session: SessionID
  let call: ToolCallID
  let id: ExecID
  let startedAt: Date
  /// The id of the message that announces the end once the call returned.
  let notice: UUID
  /// The encoded `ExecJobSpec` its row keeps.
  let spec: String
  /// Set on a job re-adopted after a restart, whose own call is long gone.
  let adopted: Bool
  let ended = OneShot<Outcome>()
  /// Held across each phase change and the write that makes it durable, so
  /// the end and the call's `running` return can never both claim the job.
  let gate = Turnstile()
  private let state: Mutex<Phase>
  private let tailBytes = Mutex<[UInt8]>([])
  static let tailCapacity = 16384

  init(session: SessionID, call: ToolCallID, id: ExecID, startedAt: Date, notice: UUID, spec: String, phase: Phase = .awaited, adopted: Bool = false) {
    self.session = session
    self.call = call
    self.id = id
    self.startedAt = startedAt
    self.notice = notice
    self.spec = spec
    self.adopted = adopted
    state = Mutex(phase)
  }

  var handle: String { execHandle(id) }

  var phase: Phase {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }

  func received(_ bytes: [UInt8]) {
    tailBytes.withLock { tail in
      tail += bytes
      if tail.count > Self.tailCapacity { tail.removeFirst(tail.count - Self.tailCapacity) }
    }
  }

  /// The end of the output so far, for the `running` return.
  var tail: String {
    let text = String(decoding: tailBytes.withLock { $0 }, as: UTF8.self)
    return ToolOutput.tail(text, maxLines: 40, maxBytes: 4096).text
  }
}

/// A value set once, awaited by any number of callers.
final class OneShot<Value: Sendable>: Sendable {
  private struct State {
    var value: Value?
    var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]
  }

  private let state = Mutex(State())

  init() {}

  var value: Value? { state.withLock { $0.value } }

  func fulfill(_ value: Value) {
    let waiters = state.withLock { state -> [CheckedContinuation<Value?, Never>] in
      guard state.value == nil else { return [] }
      state.value = value
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    for waiter in waiters { waiter.resume(returning: value) }
  }

  /// The value, or nil once the waiting task is cancelled.
  func wait() async -> Value? {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (waiter: CheckedContinuation<Value?, Never>) in
        let ready = state.withLock { state -> Value?? in
          if let value = state.value { return .some(value) }
          if Task.isCancelled { return .some(nil) }
          state.waiters[id] = waiter
          return nil
        }
        if let ready { waiter.resume(returning: ready) }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
    }
  }
}

/// One holder at a time, in arrival order. Holds are short: a phase change
/// and one store write.
actor Turnstile {
  private var held = false
  private var queue: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    guard held else {
      held = true
      return
    }
    await withCheckedContinuation { queue.append($0) }
  }

  func leave() {
    if queue.isEmpty { held = false } else { queue.removeFirst().resume() }
  }
}

extension Turnstile {
  func holding<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    await enter()
    do {
      let value = try await body()
      leave()
      return value
    } catch {
      leave()
      throw error
    }
  }
}
