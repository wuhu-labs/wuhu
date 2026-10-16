#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct WorkerProtocol.WorkerProtocolError

actor DeferredActivityReleases {
  static let capacity = 4096
  private let limit: Int
  private var active: [UUID: ExecutionWorkerActivity] = [:]
  private var starting: Set<UUID> = []
  private var pending: [UUID: ExecutionWorkerActivity] = [:]
  private var publications: Set<UUID> = []
  private var waiters: [AsyncStream<Void>.Continuation] = []
  private var flushing = false
  private var flushWaiters: [AsyncStream<Void>.Continuation] = []

  init(capacity: Int = DeferredActivityReleases.capacity) {
    precondition((1 ... Self.capacity).contains(capacity))
    limit = capacity
  }

  func publish(_ activity: ExecutionWorkerActivity, rpc: OwnerRPC) async throws {
    let id = activity.pass
    if activity.active {
      guard active[id] == nil, !starting.contains(id), active.count + starting.count < limit else { throw WorkerProtocolError(.capacityExceeded, message: "Too many tracked worker passes") }
      starting.insert(id)
    } else if pending[id] != nil { return }
    if let original = active[id], original.session != activity.session { throw WorkerProtocolError(.invalidMessage, message: "Worker pass session does not match") }
    let publication = UUID()
    publications.insert(publication)
    defer {
      starting.remove(id)
      publications.remove(publication)
      for waiter in waiters { waiter.finish() }
      waiters.removeAll()
    }
    do {
      let _: Bool = try await rpc.call("worker.activity", activity)
    } catch let error as WorkerProtocolError where error.code == .handoffTimedOut {
      guard !activity.active, active[id] != nil else { throw error }
      pending[id] = activity
      return
    }
    active[id] = activity.active ? activity : nil
  }

  func flush(using rpc: OwnerRPC) async throws {
    if flushing {
      let (stream, continuation) = AsyncStream<Void>.makeStream()
      flushWaiters.append(continuation)
      for await _ in stream {}
      try Task.checkCancellation()
      return try await flush(using: rpc)
    }
    flushing = true
    defer {
      flushing = false
      for waiter in flushWaiters { waiter.finish() }
      flushWaiters.removeAll()
    }
    let draining = publications
    while !publications.isDisjoint(with: draining) {
      let (stream, continuation) = AsyncStream<Void>.makeStream()
      waiters.append(continuation)
      for await _ in stream {}
      try Task.checkCancellation()
    }
    for (id, activity) in pending {
      let _: Bool = try await rpc.call("worker.activity", activity)
      pending[id] = nil
      active[id] = nil
    }
  }

  var pendingCount: Int { pending.count }
}
