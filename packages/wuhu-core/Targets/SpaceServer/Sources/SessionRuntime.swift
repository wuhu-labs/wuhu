import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import ExecutionOwner
import struct FileSearch.SearchError
import struct MainHub.EventSources
import class MainHub.Hub
import struct MainHub.SubscriptionFiring
import TaskLifetime
import enum WuweiNeo.Storage
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
import ModelProviders
import enum ModelProviders.ModelPlacementReason
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
  /// The sessions' loops, tools and scripts, and the verbs the routes take for a session.
  public let execution: SessionExecution
  public let attempts: AttemptHub
  /// What a session's tools present to main's API, and the line they present it over.
  let tokens: ExecTokens
  let connection: MainConnection
  let store: SessionStore
  var firing: SubscriptionFiring
  let sockets: ResponsesSocketRegistry?
  let owner: Hub
  /// Where an inference a session reports lands: `POST /v1/inferences`.
  let metrics: InferenceMetricsSink
  private let startup: (@Sendable () async -> Void)?
  let usage: UsageBoard
  let refresher: UsageRefresher?
  let warmer: CacheWarmer
  let resolveModelExecutor: @Sendable (String, String, String?) async throws -> SessionExecutor
  let resolveModelGroup: @Sendable (String, String?) async throws -> SessionExecutor
  let prepareModelRoute: @Sendable (SessionExecutor, ModelPlacementReason, SessionModelRoute?) async throws -> SessionModelRoute?
  let budget: @Sendable (SessionID) async -> ContextBudget

  init(
    execution: SessionExecution, attempts: AttemptHub, owner: Hub, access: InferenceAccess = InferenceAccess(), metrics: InferenceMetricsSink = .noop,
    tokens: ExecTokens, connection: MainConnection,
  ) {
    let usage = UsageBoard()
    self.init(
      execution: execution, attempts: attempts, usage: usage, sockets: ResponsesSocketRegistry(), refresher: nil, owner: owner, metrics: metrics,
      catalog: groupCatalog(space: owner.space, access: access), tokens: tokens, connection: connection,
    )
  }

  init(
    execution: SessionExecution,
    attempts: AttemptHub,
    usage: UsageBoard,
    sockets: ResponsesSocketRegistry?,
    refresher: UsageRefresher?,
    startup: (@Sendable () async -> Void)? = nil,
    owner: Hub,
    metrics: InferenceMetricsSink,
    catalog: @escaping @Sendable () async throws -> ProviderCatalog,
    tokens: ExecTokens,
    connection: MainConnection,
  ) {
    let space = owner.space
    self.startup = startup
    self.execution = execution
    self.metrics = metrics
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
    prepareModelRoute = modelRoutePlacer(catalog: catalog, usage: usage)
    budget = budgetResolver(space: space)
    firing = SubscriptionFiring(space: space) { execution.observe($0, $1, $2) }
  }

  /// Starts the sessions, once main's API is bound to their tools, and runs until cancelled.
  public func run() async {
    await startup?()
    execution.start()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        let (parking, continuation) = AsyncStream<Void>.makeStream()
        for await _ in parking {}
        continuation.finish()
        await execution.shutdown()
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
    eventSources: EventSources? = nil,
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
    let toolOwner = Hub(
      space: space,
      secrets: secrets,
      machines: machineSeam(hub: hub),
      resolveModelExecutor: modelExecutorResolver(space: space),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
    )
    let worker = KernelWorker(
      connection: connection, tokens: tokens, machines: hub, access: access, attempts: attempts, usage: usage,
      sources: eventSources ?? .unavailable, space: space,
    )
    return SessionRuntime(
      execution: worker.execution,
      attempts: attempts,
      usage: usage,
      sockets: worker.sockets,
      refresher: UsageRefresher(board: usage, space: space, credentials: credentials),
      startup: { await toolOwner.announceScriptRestart() },
      owner: toolOwner, metrics: metrics, catalog: catalog,
      tokens: tokens, connection: connection,
    )
  }
}

// MARK: - Tools without loops

extension SessionRuntime {
  /// Main's API bound in process to `connection`, for tools that present `tokens`. Without an `execution`, its sessions are never started: nothing runs a loop, and what is mailed to a cell waits.
  @discardableResult
  static func bindMain(
    owner: Hub, execution: SessionExecution? = nil, tokens: ExecTokens, connection: MainConnection, hub: MachineHub? = nil,
    origin: String? = nil, contentHostPattern: String? = nil, credentials: CredentialResolver = .unavailable, secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> UpgradingHandler {
    let execution = execution ?? KernelWorker(
      connection: connection, tokens: tokens, machines: hub, access: InferenceAccess(credentials: credentials), attempts: AttemptHub(), usage: UsageBoard(), space: owner.space,
    ).execution
    let runtime = SessionRuntime(
      execution: execution, attempts: AttemptHub(), owner: owner, metrics: .recording(in: owner.space), tokens: tokens, connection: connection,
    )
    return SpaceServer.configuredHandler(
      space: owner.space, hub: hub ?? MachineHub(space: owner.space), sessions: runtime, origin: origin, contentHostPattern: contentHostPattern,
      dev: true, credentials: credentials, secrets: secrets, identityController: identity, machines: owner.machines,
    )
  }

  /// The tool executor as the kernel wires it, main's API bound in process and reached as the session with the session's token, without the loops.
  static func toolExecutor(
    owner: Hub,
    hub: MachineHub? = nil,
    scripts: Scripts? = nil,
    access: InferenceAccess = InferenceAccess(),
    origin: String? = nil,
    contentHostPattern: String? = nil,
    secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> ToolExecutor {
    let tokens = ExecTokens(spaceURL: "http://main")
    let connection = MainConnection()
    bindMain(
      owner: owner, tokens: tokens, connection: connection, hub: hub,
      origin: origin, contentHostPattern: contentHostPattern, credentials: access.credentials, secrets: secrets, identity: identity,
    )
    return ToolExecutor(main: connection, credential: { tokens.sessionToken($0) }, access: access, scripts: scripts)
  }
}

func modelExecutorResolver(space: Space) -> @Sendable (String, String, String?) async throws -> SessionExecutor {
  { provider, model, effort in
    let data = try await space.fs(.settings).read(ModelsDocument.spacePath).1
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
    copy: { source, target in
      do { return try await hub.copy(from: source, to: target, caller: MachineSeam.caller) }
      catch let error as MachineHubError {
        guard case let .machineUnattached(machine) = error else { throw error }
        throw toolFailure(error, machine: machine)
      } catch let error as OperationError { throw machineOperationFailure(error) }
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
    case .text: "text"
    case .failure: "failure"
    }
  }
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
