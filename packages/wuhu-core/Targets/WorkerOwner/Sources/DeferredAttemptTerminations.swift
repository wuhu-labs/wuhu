#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.AttemptEvent
import struct SessionDomain.SessionID
import struct WorkerProtocol.WorkerProtocolError

actor DeferredAttemptTerminations {
  static let capacity = 4096
  private struct Notice {
    let session: SessionID
    var terminalObserved = false
    var reported = false
  }

  private let limit: Int
  private var starting: Set<UUID> = []
  private var publications: Set<UUID> = []
  private var publicationWaiters: [AsyncStream<Void>.Continuation] = []
  private var flushing = false
  private var flushWaiters: [AsyncStream<Void>.Continuation] = []
  private var active: [UUID: SessionID] = [:]
  private var notices: [UUID: Notice] = [:]

  init(capacity: Int = DeferredAttemptTerminations.capacity) {
    precondition((1 ... Self.capacity).contains(capacity))
    limit = capacity
  }

  func publish(session: SessionID, event: AttemptEvent, rpc: OwnerRPC) async throws {
    let id = event.attemptID
    if var notice = notices[id] {
      guard notice.session == session else { throw invalid() }
      if case .finished = event {
        notice.terminalObserved = true
        if notice.reported { active[id] = nil }
        notices[id] = notice.reported ? nil : notice
      }
      return
    }
    if case .started = event {
      guard active[id] == nil, !starting.contains(id), active.count + starting.count < limit else { throw WorkerProtocolError(.capacityExceeded, message: "Too many tracked worker attempts") }
      starting.insert(id)
    }
    let publication = UUID()
    publications.insert(publication)
    defer {
      starting.remove(id)
      publications.remove(publication)
      for waiter in publicationWaiters { waiter.finish() }
      publicationWaiters.removeAll()
    }
    do {
      let _: Bool = try await rpc.call("runtime.attempt", AttemptPublication(session: session, event: .init(event)))
    } catch let error as WorkerProtocolError where error.code == .handoffTimedOut {
      if active[id] == session {
        notices[id] = Notice(session: session, terminalObserved: { if case .finished = event { true } else { false } }())
      }
      throw error
    }
    switch event {
    case .started: active[id] = session
    case .finished: active[id] = nil
    case .delta: break
    }
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
      publicationWaiters.append(continuation)
      for await _ in stream {}
      try Task.checkCancellation()
    }
    guard notices.values.contains(where: { !$0.reported }) else { return }
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.attemptUnknownCapability)
    for (id, notice) in notices where !notice.reported {
      let _: Bool = try await rpc.call("runtime.attempt", AttemptPublication(session: notice.session, event: .unknown(id, .handoffFenceExpired)))
      guard var current = notices[id] else { continue }
      current.reported = true
      if current.terminalObserved { active[id] = nil }
      notices[id] = current.terminalObserved ? nil : current
    }
  }

  var pendingCount: Int { notices.count }
  var publishingCount: Int { publications.count }

  private func invalid() -> WorkerProtocolError { .init(.invalidMessage, message: "Worker attempt session does not match") }
}
