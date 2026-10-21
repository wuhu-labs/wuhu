import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import ExecutionOwner
import struct FileSearch.SearchError
import class MainHub.Hub
import protocol MainHub.Main
import enum MainHub.RevocationPolicy
import struct MainHub.ScriptHandlerInvocation
import struct MainHub.ScriptHandlerResult
import class MainHub.SessionService
import struct MainHub.SubscriptionFiring
import protocol MainHub.Worker
import struct MainHub.WorkerActivity
import enum MainHub.WorkerInput
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import InferenceKit
import JSONValue
import Logging
import LoopCore
import struct MachineContract.ExecID
import struct OperationProtocol.OperationError
import Serve
import SessionDomain
import SessionTools
import enum SpaceContract.ErrorCode
import enum SpaceContract.SessionToolExecutor
import SpaceCore
import SpaceTools
import Synchronization
import SystemFiles
import WuhuAI

public struct SessionRuntime: Sendable {
  let streamScope = TaskScope()
  public let service: SessionService
  /// The workers that announced themselves, and which holds each session.
  public let workers: WorkerRegistry
  /// The worker this process runs, when it runs one.
  public let inProcessWorker: SessionExecution?
  public let attempts: AttemptHub
  // What the worker presents to main's API for a mounted session, and the
  // line it presents it over.
  let tokens: ExecTokens
  let connection: MainConnection
  /// Main's API as its worker socket serves it, once the handler is built.
  let api = MainAPI()
  /// Main's OIDC signing, which workers in their own processes ask for.
  var signing = InferenceAccess()
  let store: SessionStore
  let firing: SubscriptionFiring
  let sockets: ResponsesSocketRegistry?
  let owner: Hub
  /// Where an inference a worker reports lands: `POST /v1/inferences`.
  let metrics: InferenceMetricsSink
  private let startup: (@Sendable () async -> Void)?
  let usage: UsageBoard
  let refresher: UsageRefresher?
  let warmer: CacheWarmer
  let resolveModelExecutor: @Sendable (String, String, String?) async throws -> SessionExecutor
  let resolveModelGroup: @Sendable (String, String?) async throws -> SessionExecutor
  let prepareModelRoute: @Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?
  let budget: @Sendable (SessionID) async -> ContextBudget

  init(
    space: Space, service: SessionService, workers: WorkerRegistry, inProcessWorker: SessionExecution? = nil, attempts: AttemptHub, owner: Hub,
    access: InferenceAccess = InferenceAccess(), metrics: InferenceMetricsSink = .noop, tokens: ExecTokens, connection: MainConnection,
  ) {
    startup = nil
    self.inProcessWorker = inProcessWorker
    self.metrics = metrics
    self.service = service
    self.workers = workers
    self.attempts = attempts
    self.tokens = tokens
    self.connection = connection
    store = space.sessions
    sockets = ResponsesSocketRegistry()
    usage = UsageBoard()
    refresher = nil
    warmer = CacheWarmer(space: space, usage: usage)
    let catalog = groupCatalog(space: space, access: access)
    resolveModelGroup = modelGroupExecutorResolver(catalog: catalog)
    prepareModelRoute = modelRoutePreparer(catalog: catalog, usage: usage)
    self.owner = owner
    resolveModelExecutor = modelExecutorResolver(space: space)
    budget = budgetResolver(owner: owner)
    firing = SubscriptionFiring(space: space, worker: workers)
  }

  init(
    space: Space,
    service: SessionService,
    attempts: AttemptHub,
    usage: UsageBoard,
    sockets: ResponsesSocketRegistry?,
    refresher: UsageRefresher?,
    workers: WorkerRegistry,
    inProcessWorker: SessionExecution?,
    startup: (@Sendable () async -> Void)? = nil,
    owner: Hub,
    metrics: InferenceMetricsSink,
    catalog: @escaping @Sendable () async throws -> ProviderCatalog,
    tokens: ExecTokens,
    connection: MainConnection,
  ) {
    self.startup = startup
    self.inProcessWorker = inProcessWorker
    self.metrics = metrics
    self.service = service
    self.workers = workers
    self.attempts = attempts
    self.tokens = tokens
    self.connection = connection
    store = space.sessions
    self.usage = usage
    self.sockets = sockets
    self.refresher = refresher
    warmer = CacheWarmer(space: space, usage: usage)
    self.owner = owner
    resolveModelExecutor = modelExecutorResolver(space: space)
    resolveModelGroup = modelGroupExecutorResolver(catalog: catalog)
    prepareModelRoute = modelRoutePreparer(catalog: catalog, usage: usage)
    budget = budgetResolver(owner: owner)
    firing = SubscriptionFiring(space: space, worker: workers)
  }

  public func run() async {
    await startup?()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          try await service.start()
        } catch is CancellationError {
        } catch {
          Logger(label: "wuhu.session-runtime").error("session service stopped", metadata: ["error": "\(error)"])
        }
      }
      group.addTask { await firing.run() }
      group.addTask { await warmer.run() }
      if let sockets { group.addTask { await sockets.run() } }
      if let refresher {
        group.addTask { await refresher.run() }
      }
      await group.waitForAll()
    }
    await streamScope.close()
  }
}

extension SessionRuntime {
  public static func assemble(
    space: Space,
    hub: MachineHub,
    attemptLog: AttemptLogConfig? = nil,
    metrics: InferenceMetricsSink = .noop,
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
  ) async -> SessionRuntime {
    await assemble(
      space: space, hub: hub, attemptLog: attemptLog, metrics: metrics, credentials: credentials,
      secrets: secrets, usage: UsageBoard(),
    )
  }

  static func assemble(
    space: Space,
    hub: MachineHub,
    attemptLog: AttemptLogConfig?,
    metrics: InferenceMetricsSink,
    credentials: CredentialResolver,
    secrets: SpaceSecretStores?,
    usage: UsageBoard,
    tokens: ExecTokens? = nil,
    oidcToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    oidcReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    outOfProcess: Bool = false,
    takingOver: Bool = false,
  ) async -> SessionRuntime {
    let attempts = AttemptHub()
    let tokens = tokens ?? ExecTokens(spaceURL: "http://main")
    let connection = MainConnection()
    // What this process brings to the inferences it runs; the catalog is data
    // in the space (`wuhu models update`), re-read per use, never cached at boot.
    let access = InferenceAccess(
      credentials: credentials, oidcToken: oidcToken, oidcReadiness: oidcReadiness, oidcBindingIdentity: oidcBindingIdentity,
      trace: attemptLog?.traceClient,
    )
    let catalog = groupCatalog(space: space, access: access)
    let machines = machineSeam(hub: hub)
    let toolOwner = Hub(
      space: space,
      secrets: secrets,
      machines: machines,
      resolveModelExecutor: modelExecutorResolver(space: space),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
    )
    // The loop, the kernel pieces and the tools reach main as a worker does:
    // through its routes, with the worker's token. `toolOwner` serves them.
    let workers = WorkerRegistry(tokens: tokens)
    // A main taking over from the one before it in this process stopped no
    // script: they run on in the workers.
    let startup: (@Sendable () async -> Void)? = takingOver ? nil : { @Sendable in
      await toolOwner.announceScriptRestart()
    }
    // Out of process, the workers announce themselves over main's worker socket.
    var worker: KernelWorker?
    if !outOfProcess {
      let credential = workers.mint()
      let inProcess = await KernelWorker(connection: connection, credential: credential.token, access: access, attempts: attempts, usage: usage)
      workers.announce(credential.id, endpoint: inProcess.execution)
      worker = inProcess
    }
    let service = SessionService(
      sessions: space.sessions, worker: workers,
      archived: { session in
        do {
          for record in try await space.liveToolExecs(caller: session.rawValue) {
            do { try await hub.kill(record.id) }
            catch { Logger(label: "wuhu.exec").error("could not kill archived session's exec: \(error)") }
          }
        } catch { Logger(label: "wuhu.exec").error("could not read archived session's live execs: \(error)") }
        do { try await space.forgetOwedExecs(caller: session.rawValue) }
        catch { Logger(label: "wuhu.exec").error("could not retire archived session's owed exec ends: \(error)") }
        tokens.revokeSession(session)
      },
    )
    var runtime = SessionRuntime(
      space: space,
      service: service,
      attempts: attempts,
      usage: usage,
      sockets: worker?.sockets,
      refresher: UsageRefresher(board: usage, space: space, credentials: credentials),
      workers: workers,
      inProcessWorker: worker?.execution,
      startup: startup,
      owner: toolOwner, metrics: metrics, catalog: catalog,
      tokens: tokens, connection: connection,
    )
    runtime.signing = access
    return runtime
  }
}

// MARK: - Tools without loops

// A worker that is only its tool executor: nothing runs a loop. Tests of the
// tools alone take it.
struct ToolOnlyWorker: Worker {
  // No loop is mounted, so a verb reaches nothing and a revocation is settled at once.
  func deliver(_ session: SessionID, _ input: WorkerInput) async throws {}
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool { true }
  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { preconditionFailure("no loops run behind a tool-only worker") }
  func activity() async -> WorkerActivity { WorkerActivity(scripts: [:]) }
  func runningWork(_ session: SessionID) async throws -> [String] { [] }
  func shutdown() async {}
}

extension SessionRuntime {
  /// Main's API bound in process to the announced `workers` as the kernel
  /// binds it, with no loops running: what a test of the tools alone needs.
  @discardableResult
  static func bindMain(
    owner: Hub, workers: WorkerRegistry, tokens: ExecTokens, connection: MainConnection, hub: MachineHub? = nil,
    origin: String? = nil, contentHostPattern: String? = nil, credentials: CredentialResolver = .unavailable, secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> UpgradingHandler {
    let runtime = SessionRuntime(
      space: owner.space, service: SessionService(sessions: owner.space.sessions, worker: workers),
      workers: workers, attempts: AttemptHub(), owner: owner, metrics: .recording(in: owner.space), tokens: tokens, connection: connection,
    )
    return SpaceServer.configuredHandler(
      space: owner.space, hub: hub ?? MachineHub(space: owner.space), sessions: runtime, origin: origin, contentHostPattern: contentHostPattern,
      dev: true, credentials: credentials, secrets: secrets, identityController: identity, machines: owner.machines,
    )
  }

  /// The tool executor as the kernel wires it, main's API bound in process and
  /// reached as the session with the session's token, without the loops.
  static func toolExecutor(
    owner: Hub,
    hub: MachineHub? = nil,
    scripts: Scripts? = nil,
    execJobs: ExecJobs = ExecJobs(),
    access: InferenceAccess = InferenceAccess(),
    origin: String? = nil,
    contentHostPattern: String? = nil,
    secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> ToolExecutor {
    let tokens = ExecTokens(spaceURL: "http://main")
    let connection = MainConnection()
    let workers = WorkerRegistry(tokens: tokens)
    let credential = workers.mint()
    let executor = ToolExecutor(
      owner: MainClient(connection: connection, credential: { credential.token }), main: connection, credential: { tokens.sessionToken($0) },
      access: access, scripts: scripts, execJobs: execJobs,
    )
    workers.announce(credential.id, endpoint: ToolOnlyWorker())
    bindMain(
      owner: owner, workers: workers, tokens: tokens, connection: connection, hub: hub,
      origin: origin, contentHostPattern: contentHostPattern, credentials: access.credentials, secrets: secrets, identity: identity,
    )
    return executor
  }
}

func modelExecutorResolver(space: Space) -> @Sendable (String, String, String?) async throws -> SessionExecutor {
  { provider, model, effort in
    let data = try await space.fs(.shared).read(ModelsDocument.spacePath).1
    let catalog = ProviderCatalog(document: try ModelsDocument(json: data), credentials: .unavailable)
    if let effort {
      let specifier = ModelSpecifier(provider: provider, model: model, effort: effort)
      try catalog.validate(specifier)
      return .kernel(specifier)
    }
    return try .kernel(catalog.defaultSpecifier(provider: provider, model: model))
  }
}

func machineSeam(hub: MachineHub) -> MachineSeam {
  MachineSeam(
    vfs: { machine, op in
      do { return try await hub.vfs(machine: machine, op: op, caller: MachineSeam.caller) }
      catch let error as MachineHubError { throw toolFailure(error, machine: machine) }
      catch let error as OperationError { throw machineOperationFailure(error) }
    },
    search: { machine, query in
      do { return try await hub.search(machine: machine, query: query, caller: MachineSeam.caller) }
      catch let error as MachineHubError { throw toolFailure(error, machine: machine) }
      catch let error as OperationError { throw machineOperationFailure(error) }
      catch let error as SearchError { throw searchFailure(error) }
    },
    attached: { await hub.attachedMachines() },
  )
}

// The fallback compaction is deliberately mechanical: it runs when the model
// (or provider) failed to produce a compact call, so it must not depend on
// another inference. Open goals and subscriptions are carried by the
// generation-head snapshot; dropped file knowledge re-establishes through
// read-before-write failures.
func mechanicalCompaction(of transcript: Transcript, images: ImageLimits, keptTokens: Int = 8192) -> CompactionResult {
  let cut = transcript.compactionCutIndex(keptTokens: keptTokens, images: images)
  let folded = cut.map { Array(transcript.items[..<$0]) } ?? transcript.items
  let kept = cut.map { $0 ..< transcript.items.count }
  let digest = folded.suffix(80).map(digestLine).joined(separator: "\n")
  let summary = """
  Mechanical compaction: context overflowed and the model could not produce a \
  compact call, so \(folded.count) earlier item(s) were folded without model \
  summarization. Digest of the most recent folded items (oldest first):
  \(digest)
  """
  return CompactionResult(summary: summary, kept: kept)
}

private func digestLine(_ item: TranscriptItem) -> String {
  func clip(_ text: String, to limit: Int = 160) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
  }
  switch item {
  case let .direct(message):
    return "- direct \(message.sender.id): \(clip(message.content.text))"
  case let .message(message):
    return "- \(message.kind.rawValue) \(message.sender.id) [\(message.conversationID.rawValue)]: \(clip(message.content.text))"
  case let .notification(notification):
    return "- notification: \(clip(notification.content.text))"
  case let .assistant(entry):
    let calls = entry.toolCalls.map(\.name)
    let text = entry.content.compactMap { block -> String? in
      guard case let .text(text) = block else { return nil }
      return text.text
    }.joined(separator: " ")
    let suffix = calls.isEmpty ? "" : " [calls: \(calls.joined(separator: ", "))]"
    return "- assistant: \(clip(text))\(suffix)"
  case let .toolResult(result):
    return "- tool result (\(result.payload.digestName))"
  case let .bookmark(marker):
    return "- bookmark \(marker.name ?? "(unnamed)")"
  case let .generationHead(head):
    return "- earlier summary: \(clip(head.summary))"
  }
}

extension ToolResultPayload {
  fileprivate var digestName: String {
    switch self {
    case .read: "read"
    case .write: "write"
    case .edit: "edit"
    case .grep: "grep"
    case .find: "find"
    case .exec: "exec"
    case .mount: "mount"
    case .machines: "machines"
    case .templates: "templates"
    case .observe: "observe"
    case .timer: "timer"
    case .cancelObservation, .cancelTimer: "cancel"
    case .query: "query"
    case .sendMessage: "send_message"
    case .request: "request"
    case .report: "report"
    case .createSession: "create_session"
    case .setTitle: "set_title"
    case .manipulateUI: "manipulate_ui"
    case .compact: "compact"
    case .script: "script"
    case .failure: "failure"
    }
  }
}

// A kernel session's prompt, frozen at its prompt revision.
func systemPrompt(space: Space, record: SessionRecord) async throws -> String {
  kernelPrompt(for: record, home: try await space.sessionHome(record.id, at: try await space.sessions.activatePromptRevision(record.id)))
}

private func machineOperationFailure(_ error: OperationError) -> ToolRunError {
  let code: ErrorCode = switch error.code {
  case .unknownKind: .unknownKind
  case .invalidInput, .invalidOffset, .inputTooLarge: .invalidArgument
  case .unsupportedProtocol: .unsupported
  case .machineNotAuthorized, .credentialExpired: .unauthorized
  case .fileChanged, .operationExists, .invocationConflict: .conflict
  case .unknownMachine: .notFound
  default: .unavailable
  }
  return .failed(code: code, message: "\(error.code.rawValue): \(error.message)", hint: nil)
}

/// Main's API handler, as `configuredHandler` builds it: what the worker
/// socket serves.
final class MainAPI: Sendable {
  private let handler = Mutex<UpgradingHandler?>(nil)

  func bind(_ api: @escaping UpgradingHandler) { handler.withLock { $0 = api } }

  func callAsFunction(_ request: Request) async throws -> UpgradeResult {
    guard let api = handler.withLock({ $0 }) else { return .response(Response(status: .serviceUnavailable)) }
    return try await api(request)
  }
}
