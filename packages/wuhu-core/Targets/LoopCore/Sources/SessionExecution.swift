import Dependencies
import Logging
import struct MainHub.ArchiveBusySession
import func MainHub.handlerScriptID
import enum MainHub.ObserverMail
import struct MainHub.ScriptHandlerResult
import struct MainHub.ScriptRun
import enum MainHub.SessionError
import struct MainHub.SubtreeArchiveBusy
import SessionTools
import enum SpaceContract.ScriptOutput
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore

/// The sessions' runtime: the loops, the tools and the scripts, the handler slots' observer cells, and the verbs main's routes take for a session. Each loop is a session cell on wuwei's shared backend over `space`'s database. Nothing runs until `start`: mail waits in the store.
public struct SessionExecution: Sendable {
  private let space: Space
  private let client: LoopClient
  let store: SessionStore
  private let scripts: Scripts
  public let tools: ToolExecutor
  private let running: @Sendable (SessionID) async throws -> [String]
  private let archiveGrace: Duration
  private let archived: @Sendable (SessionID) async -> Void
  private let log = Logger(label: "wuhu.session-execution")

  /// `archived` hears of each session an archive took, after its cell was told.
  public init(
    connection: MainConnection,
    credential: @escaping @Sendable (SessionID) async throws -> String,
    access: InferenceAccess = InferenceAccess(),
    space: Space,
    scripts: Scripts? = nil,
    archiveGrace: Duration = .seconds(24 * 3600),
    archived: @escaping @Sendable (SessionID) async -> Void = { _ in },
    observerRun: @escaping ObserverRun = { _, _, _ in preconditionFailure("this worker runs no group observer") },
    loopConfig: @Sendable (ToolExecutor) -> LoopConfig,
  ) {
    let scripts = scripts ?? Scripts(sessions: space.sessions)
    let tools = ToolExecutor(main: connection, credential: credential, access: access, scripts: scripts)
    self.scripts = scripts
    self.tools = tools
    self.archiveGrace = archiveGrace
    self.archived = archived
    var config = loopConfig(tools)
    let runningWork = config.runningWork
    config.runningWork = { session in
      scripts.running(of: session) + (try await runningWork(session))
    }
    running = config.runningWork
    @Dependency(\.continuousClock) var clock
    self.space = space
    let handler: @Sendable (HandlerJob.Params) async throws -> ScriptHandlerResult = { params in
      switch params.owner {
      case let .session(session):
        return try await scripts.runHandler(id: params.firing, path: params.path, actor: .session(session), input: params.input, tools: tools)
      case let .group(group):
        let observer = Observer(group: group, name: params.name!, firing: params.firing.uuidString.lowercased())
        return try await observerRun(observer, handlerScriptID(params.firing)) { token in
          try await scripts.runHandler(id: params.firing, path: params.path, actor: .observer(observer, token: token), input: params.input, tools: tools)
        }
      }
    }
    client = withEscapedDependencies { [config] dependencies in
      LoopClient(
        store: space.sessions, config: config, sleep: { deadlineSleep(after: $0, clock: clock) }, dependencies: dependencies, scheduler: space.worker.scheduler,
        handler: handler,
      )
    }
    store = space.sessions
  }

  private var loops: Wuwei.Worker {
    space.worker
  }

  /// Gives the space's worker the loops' kinds and starts it: it takes the mail that waited and whatever a restart left to run.
  public func start() {
    let loops = loops
    guard !loops.isStarted else { return }
    // The client first: a worker hosts a kind from the moment it is registered, and a poke may land before `start`.
    loops.provide(client)
    for kind: Registration in [
      .cell(SessionCell.self), .cell(ObserverCell.self),
      .job(InferenceJob.self), .job(ToolCallJob.self), .job(CompactionJob.self), .job(StreamJob.self), .job(HandlerJob.self),
    ] {
      loops.register(kind)
    }
    loops.start()
  }

  public func shutdown() async {
    await space.stopWorker()
    await scripts.close()
  }

  private func cell(_ session: SessionID) -> SessionCell.Sender {
    loops.send(SessionCell.ID(session.rawValue))
  }

  public func retitle(_ session: SessionID, to title: String) async throws -> String {
    let title = try SessionStore.usableTitle(title)
    _ = try await store.record(session)
    cell(session).retitle(title)
    return title
  }

  public func retag(_ session: SessionID, to tags: [String]) async throws {
    _ = try await store.record(session)
    cell(session).retag(tags)
  }

  public func compact(_ session: SessionID, instructions: String?) async throws {
    if try await store.record(session).kind == .task, instructions?.isEmpty == false {
      throw SessionStoreError.taskTakesNoHumanInput(session.rawValue)
    }
    cell(session).compact(instructions)
  }

  public func interrupt(_ session: SessionID) async throws {
    _ = try await store.record(session)
    cell(session).interrupt()
  }

  public func resume(_ session: SessionID) async throws {
    try await store.record(session).executor.requireSupported()
    do {
      // What the loop could not read is refused here, not found by it.
      _ = try await store.hydrate(session)
    } catch where error is DecodingError || error is ExecutorSpecError || (error as? CocoaError)?.code == .formatting {
      log.error("resume failed", metadata: ["session": "\(session.rawValue)", "error": "\(error)"])
      try await store.markErrored(session, message: "resume failed: \(SessionError.unreadableData(session))")
      cell(session).cancel()
      throw SessionError.unreadableData(session)
    }
    cell(session).resume()
  }

  /// Best effort: busy sessions refuse the whole subtree unless `force`; one that turns busy after the check is archived anyway.
  public func archive(_ session: SessionID, force: Bool = false) async throws {
    let subtree = try await store.archiveSubtree(session).filter { $0.lifecycle == .live }
    if !force {
      var busy: [ArchiveBusySession] = []
      for record in subtree where !record.executor.isRetired {
        if try await !settled(record.id) { busy.append(ArchiveBusySession(id: record.id, title: record.title)) }
      }
      guard busy.isEmpty else { throw SubtreeArchiveBusy(sessions: busy) }
    }
    // Parents first: a child's failed request reaches a parent already archived, which does not start on it.
    for record in subtree.reversed() {
      try await store.closeRequestsForArchive(record.id)
      scripts.stopScripts(of: record.id)
      cell(record.id).archive(archiveGrace)
      await archived(record.id)
    }
  }

  /// The reply is read before the cell restarts: the generation it names is the one the restart opens unless another restart lands first.
  public func restart(_ session: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute? = nil) async throws -> SessionRestart {
    let record = try await store.record(session)
    try (executor ?? record.executor).requireSupported()
    guard record.lifecycle == .live else { throw SessionStoreError.restartOfArchivedSession(session.rawValue) }
    if !record.executor.isRetired, try await !settled(session) {
      throw SessionStoreError.busyForRestart(session.rawValue)
    }
    let stored = executor == nil && modelRoute == nil ? record.executor : try SessionStore.restartExecutor(executor ?? record.executor, route: modelRoute)
    let generation = try await store.generation(session) + 1
    cell(session).restart(executor, modelRoute, note, try await running(session))
    return SessionRestart(generation: generation, executor: stored)
  }

  public func unarchive(_ session: SessionID) async throws {
    @Dependency(\.date.now) var now
    let record = try await store.record(session)
    guard case let .archived(graceExpiresAt) = record.lifecycle else { return }
    try record.executor.requireSupported()
    guard now < graceExpiresAt else { throw SessionStoreError.archiveGraceExpired(session.rawValue) }
    cell(session).unarchive()
  }

  /// Whether the session has nothing to do, now or once its job answers or its cell takes its mail; the caller writes what it then does before the next wake reaches the cell.
  private func settled(_ session: SessionID) async throws -> Bool {
    guard try await store.pendingCommand(session) == nil else { return false }
    if try await store.record(session).stopped { return true }
    guard !loops.hasMail(for: SessionCell.ID(session.rawValue).recipient) else { return false }
    let state = SessionState(try await store.hydrate(session))
    return state.settled && (state.slot.working(exists: { [loops] work in
      switch work {
      case let .step(id): loops.exists(id)
      case let .call(id): loops.exists(id)
      case let .compaction(id): loops.exists(id)
      }
    }, outcome: { [loops] in loops.job($0).outcome() }) == nil)
  }

  /// The session's lines as `viewer` reads them, past `after` (`TranscriptTail`); the stream ends when the cell closes the socket.
  public func lines(_ session: SessionID, after: TranscriptCursor?, as viewer: Principal) -> AsyncStream<TranscriptTail.Outgoing> {
    AsyncStream { [loops] continuation in
      let peer = loops.attach(TranscriptTail.self, to: SessionCell.ID(session.rawValue), opening: .init(after: after, viewer: viewer)) { output in
        switch output {
        case let .frame(frame): continuation.yield(frame)
        case .closed: continuation.finish()
        }
      }
      continuation.onTermination = { _ in peer?.close() }
      if peer == nil { continuation.finish() }
    }
  }

  /// Mail to a handler slot's observer cell.
  public func observe(_ owner: SubscriptionOwner, _ subscription: SubscriptionID, _ mail: ObserverMail) {
    let cell = loops.send(ObserverCell.ID(owner, subscription))
    switch mail {
    case .look: cell.look()
    case let .rows(input, marker): cell.observed(input, marker)
    }
  }

  /// Runs `script` until it ends, `output` taking what it says as it says it; cancelling the call kills it.
  public func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    try await scripts.run(script, tools: tools, output: output)
  }
}

/// Runs a group observer's handler: `body` gets the token minted for this firing alone, which ends with the call, and so does every machine process its script started.
public typealias ObserverRun = @Sendable (Observer, _ script: String, (String) async throws -> ScriptHandlerResult) async throws -> ScriptHandlerResult
