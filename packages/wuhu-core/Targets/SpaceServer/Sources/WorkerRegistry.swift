#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MainHub
import SessionDomain
import enum SpaceContract.ScriptOutput
import Synchronization

/// What a worker presents on its line to main: the id main knows it by and
/// the token its routes take.
public struct WorkerCredential: Sendable {
  public let id: WorkerID
  public let token: String
}

/// A worker main has drained, or never announced.
public struct UnknownWorkerError: Error, CustomStringConvertible {
  public let id: WorkerID
  public var description: String { "unknown worker: \(id.rawValue)" }
}

/// Main's registry of workers: who has announced itself, and which of them
/// holds each session. It is the `Worker` main's scheduler and subscription
/// firing talk to. A session's verb goes to the worker holding it, assigned
/// on first contact to the least loaded one; `drain` moves a worker's
/// sessions to the others and forgets it. Main holds nothing of a worker but
/// what it announced; a worker that announces again with its id replaces its
/// line and keeps its sessions.
public final class WorkerRegistry: Worker, Sendable {
  private struct State {
    var lines: [WorkerID: any Worker] = [:]
    // Announce order breaks ties in assignment.
    var order: [WorkerID] = []
    var assignment: [SessionID: WorkerID] = [:]
    var awaiting: [WorkerID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    func load(of worker: WorkerID) -> Int { assignment.values.count { $0 == worker } }

    func leastLoaded(excluding drained: WorkerID? = nil) -> WorkerID? {
      order.filter { $0 != drained }.min { load(of: $0) < load(of: $1) }
    }
  }

  private let state = Mutex(State())
  private let minted = Mutex(0)
  private let tokens: ExecTokens

  init(tokens: ExecTokens) {
    self.tokens = tokens
  }

  /// A worker's credential, minted before it announces: its line to main
  /// carries the token, and `announce` takes the id.
  public func mint() -> WorkerCredential {
    // Numbered, not drawn from the uuid dependency: a replayed session tree
    // must see the same uuids as when it was recorded.
    let id = WorkerID("worker-\(minted.withLock { $0 += 1; return $0 })")
    return WorkerCredential(id: id, token: tokens.workerToken(id))
  }

  /// The worker is up behind `endpoint`, holding `held`; announced again
  /// with its id, it replaces its line and keeps its sessions.
  public func announce(_ id: WorkerID, endpoint: any Worker, holding held: [SessionID] = []) {
    precondition(tokens.hasWorker(id), "a worker announces with the id main minted for it: \(id.rawValue)")
    let waiters = state.withLock { state in
      if state.lines[id] == nil { state.order.append(id) }
      state.lines[id] = endpoint
      for session in held { state.assignment[session] = id }
      return state.awaiting.removeValue(forKey: id)?.values.map(\.self) ?? []
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once the worker has announced itself, or when cancelled.
  func announcement(of id: WorkerID) async {
    let waiter = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let waits = state.withLock { state in
          guard state.lines[id] == nil, !Task.isCancelled else { return false }
          state.awaiting[id, default: [:]][waiter] = continuation
          return true
        }
        if !waits { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.awaiting[id]?.removeValue(forKey: waiter) }?.resume()
    }
  }

  /// How many credentials have been minted: a main taking over goes on from
  /// there, so no two workers share an id.
  var mintedCount: Int { minted.withLock { $0 } }

  func restore(mintedCount: Int) { minted.withLock { $0 = max($0, mintedCount) } }

  /// A worker gone without handing its sessions off: its line and its token
  /// end, and the sessions it held are nobody's until their next verb assigns
  /// them. Returns those sessions.
  func drop(_ id: WorkerID) -> [SessionID] {
    let sessions = state.withLock { state -> [SessionID] in
      let held = state.assignment.filter { $0.value == id }.keys.sorted { $0.rawValue < $1.rawValue }
      for session in held { state.assignment[session] = nil }
      state.lines[id] = nil
      state.order.removeAll { $0 == id }
      return held
    }
    tokens.revokeWorker(id)
    return sessions
  }

  /// Lets go of every worker without telling them: what main does as another
  /// main takes over. Their tokens stay, so they announce again to it.
  func detach() {
    state.withLock { state in
      state.lines = [:]
      state.order = []
      state.assignment = [:]
    }
  }

  public var workers: [WorkerID] { state.withLock(\.order) }

  public func worker(of session: SessionID) -> WorkerID? { state.withLock { $0.assignment[session] } }

  /// Moves every session the worker holds to the others and forgets it: each
  /// loop is handed off at the end of its step in flight, reassigned, and
  /// woken there, where it hydrates from the store and goes on with the same
  /// transcript. The worker's token ends with it, so nothing it still holds
  /// can write.
  @discardableResult
  public func drain(_ id: WorkerID) async throws -> any Worker {
    let (line, sessions) = state.withLock { state -> ((any Worker)?, [SessionID]) in
      (state.lines[id], state.assignment.filter { $0.value == id }.keys.sorted { $0.rawValue < $1.rawValue })
    }
    guard let line else { throw UnknownWorkerError(id: id) }
    for session in sessions {
      _ = try await line.revoke(session, policy: .handOff)
      let next = state.withLock { state -> (any Worker)? in
        guard let target = state.leastLoaded(excluding: id) else {
          state.assignment[session] = nil
          return nil
        }
        state.assignment[session] = target
        return state.lines[target]
      }
      try await next?.deliver(session, .wake)
    }
    state.withLock { state in
      state.lines[id] = nil
      state.order.removeAll { $0 == id }
    }
    tokens.revokeWorker(id)
    return line
  }

  // The worker holding the session, assigned now if none does.
  private func line(of session: SessionID) throws -> any Worker {
    try state.withLock { state in
      if let held = state.assignment[session], let line = state.lines[held] { return line }
      guard let target = state.leastLoaded() else { throw NoWorkerError() }
      state.assignment[session] = target
      return state.lines[target]!
    }
  }

  private var lines: [any Worker] { state.withLock { state in state.order.compactMap { state.lines[$0] } } }

  // MARK: Worker

  public func deliver(_ session: SessionID, _ input: WorkerInput) async throws {
    try await line(of: session).deliver(session, input)
    if case .archived = input {
      state.withLock { $0.assignment[session] = nil }
    }
  }

  // A revocation asks the session's worker whether it has settled, so a session
  // nobody holds yet is assigned first: its worker reads the record and answers.
  public func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    try await line(of: session).revoke(session, policy: policy)
  }

  public func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    try await line(of: invocation.session).fire(invocation)
  }

  public func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    try await line(of: script.session).run(script, output: output)
  }

  public func runningWork(_ session: SessionID) async throws -> [String] {
    try await line(of: session).runningWork(session)
  }

  public func activity() async -> WorkerActivity {
    var scripts: [ScriptRunID: SessionID] = [:]
    for line in lines {
      scripts.merge(await line.activity().scripts) { _, new in new }
    }
    return WorkerActivity(scripts: scripts)
  }

  public func shutdown() async {
    for line in lines { await line.shutdown() }
  }
}
