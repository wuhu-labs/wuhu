#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import class Clocks.AnyClock
import Dependencies

extension WorkerClient {
  public func withOwnerTransaction<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    try await ownerTransactions.run(operation)
  }

  public func pauseOwnerTransactions(_ token: UUID, drainTimeout: Duration = .seconds(10), waitTimeout: Duration = .seconds(30)) async throws {
    try await ownerTransactions.pause(token, drainTimeout: drainTimeout, waitTimeout: waitTimeout)
  }

  public func requireOwnerTransactionsPaused(_ token: UUID, acceptingExpired: Bool = false) async throws {
    try await ownerTransactions.requirePaused(token, acceptingExpired: acceptingExpired)
  }

  @discardableResult public func resumeOwnerTransactions(_ token: UUID, afterResume: @Sendable () async throws -> Void = {}) async throws -> Bool {
    guard try await ownerTransactions.resume(token) else { return false }
    try await afterResume()
    try await ownerTransactions.completeResume(token)
    return true
  }
}

actor WorkerOwnerTransactions {
  private struct Fence {
    let token: UUID
    let deadline: AnyClock<Duration>.Instant
  }

  private let clock: AnyClock<Duration>
  private var fence: Fence?
  private enum Resume {
    case rolledBack(UUID), repairing(UUID), complete(UUID)
    var token: UUID { switch self { case let .rolledBack(id), let .repairing(id), let .complete(id): id } }
  }

  private var lastResume: Resume?
  private var closed = false
  private var active = 0
  private var changed: [UUID: AsyncStream<Void>.Continuation] = [:]
  var pausedToken: UUID? { fence?.token }
  var waitingCount: Int { changed.count }

  init() {
    @Dependency(\.continuousClock) var clock
    self.clock = AnyClock(clock)
  }

  func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    while let fence {
      try requireOpen()
      try await wait(until: fence.deadline)
      guard clock.now < fence.deadline else { throw timeout() }
    }
    try requireOpen()
    try Task.checkCancellation()
    active += 1
    defer { active -= 1; notify() }
    return try await operation()
  }

  func pause(_ token: UUID, drainTimeout: Duration, waitTimeout: Duration) async throws {
    try requireOpen()
    if case .repairing = lastResume { throw invalid() }
    guard fence == nil, drainTimeout > .zero, waitTimeout > drainTimeout else { throw invalid() }
    fence = Fence(token: token, deadline: clock.now.advanced(by: waitTimeout))
    let deadline = clock.now.advanced(by: drainTimeout)
    do {
      while active > 0 {
        try await wait(until: deadline)
        guard fence?.token == token else { throw invalid() }
        try requireOpen()
      }
      try Task.checkCancellation()
      try requirePaused(token)
    } catch {
      if fence?.token == token { lastResume = .rolledBack(token); fence = nil; notify() }
      throw error
    }
  }

  func requirePaused(_ token: UUID, acceptingExpired: Bool = false) throws {
    try requireOpen()
    guard let fence, fence.token == token, active == 0 else { throw invalid() }
    guard acceptingExpired || clock.now < fence.deadline else { throw timeout() }
  }

  @discardableResult func resume(_ token: UUID) throws -> Bool {
    try requireOpen()
    if fence == nil, lastResume?.token == token {
      if case .repairing = lastResume { return true }
      return false
    }
    guard fence?.token == token else { throw invalid() }
    lastResume = .repairing(token)
    fence = nil
    notify()
    return true
  }

  func completeResume(_ token: UUID) throws {
    try requireOpen()
    guard fence == nil, lastResume?.token == token else { throw invalid() }
    lastResume = .complete(token)
  }

  func close() { closed = true; notify() }

  private func wait(until deadline: AnyClock<Duration>.Instant) async throws {
    guard clock.now < deadline else { throw timeout() }
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    changed[id] = continuation
    defer { changed[id] = nil }
    let clock = clock
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        for await _ in stream {}
        try Task.checkCancellation()
      }
      group.addTask {
        try await clock.sleep(until: deadline, tolerance: nil)
        throw WorkerProtocolError(.handoffTimedOut, message: "Worker owner transaction fence timed out")
      }
      _ = try await group.next()
    }
  }

  private func notify() {
    let continuations = Array(changed.values)
    changed.removeAll()
    for continuation in continuations { continuation.finish() }
  }

  private func requireOpen() throws {
    guard !closed else { throw WorkerProtocolError(.unavailable, message: "Worker owner transactions are closed") }
  }

  private func invalid() -> WorkerProtocolError { .init(.invalidConfiguration, message: "Worker owner transaction fence does not match") }
  private func timeout() -> WorkerProtocolError { .init(.handoffTimedOut, message: "Worker owner transaction fence timed out") }
}
