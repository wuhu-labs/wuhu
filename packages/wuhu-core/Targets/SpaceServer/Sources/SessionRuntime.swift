import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import ExecutionOwner
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
import struct WorkerOwner.WorkerRuntimeOwner
import WuhuAI

public struct SessionRuntime: Sendable {
  public let service: SessionService
  public let attempts: AttemptHub
  let store: SessionStore
  let firing: SubscriptionFiring
  let scripts: Scripts?
  let sockets: ResponsesSocketRegistry?
  private let discoveryOwner: InProcessToolOwnerClient?
  private let startup: (@Sendable () async -> Void)?
  let usage: UsageBoard
  let refresher: UsageRefresher?
  let warmer: CacheWarmer
  let resolveModelExecutor: @Sendable (String, String, String?) async throws -> SessionExecutor
  let resolveModelGroup: @Sendable (String, String?) async throws -> SessionExecutor
  let prepareModelRoute: @Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?
  let budget: @Sendable (SessionID) async -> ContextBudget

  public init(space: Space, service: SessionService, attempts: AttemptHub, credentials: CredentialResolver = .environmentOnly) {
    startup = nil
    self.service = service
    self.attempts = attempts
    store = space.sessions
    sockets = ResponsesSocketRegistry()
    usage = UsageBoard()
    refresher = nil
    warmer = CacheWarmer(space: space, usage: usage)
    let executionOwner = InProcessExecutionOwnerClient(space: space, credentials: credentials)
    let catalog = groupCatalog(owner: executionOwner)
    resolveModelGroup = modelGroupExecutorResolver(catalog: catalog)
    prepareModelRoute = modelRoutePreparer(catalog: catalog, usage: usage)
    let owner: any WorkerOwnerClient = InProcessToolOwnerClient(
      space: space, executionOwner: executionOwner,
      resolveModelExecutor: modelExecutorResolver(owner: executionOwner),
      resolveModelGroup: resolveModelGroup, prepareModelRoute: prepareModelRoute,
    )
    discoveryOwner = owner as? InProcessToolOwnerClient
    resolveModelExecutor = modelExecutorResolver(owner: owner)
    budget = budgetResolver(owner: owner)
    scripts = Scripts(owner: owner)
    firing = SubscriptionFiring(space: space, scripts: scripts, tools: ToolExecutor(owner: owner, scripts: scripts))
    scripts?.configureDiscovery(toolRosters: sessionToolRosters())
  }

  init(
    space: Space,
    service: SessionService,
    attempts: AttemptHub,
    usage: UsageBoard,
    sockets: ResponsesSocketRegistry?,
    refresher: UsageRefresher?,
    scripts: Scripts?,
    handler: any HandlerExecutionClient,
    startup: (@Sendable () async -> Void)? = nil,
    owner: any ExecutionOwnerClient,
    catalog: @escaping @Sendable () async throws -> ProviderCatalog,
  ) {
    self.startup = startup
    self.service = service
    self.attempts = attempts
    store = space.sessions
    self.usage = usage
    self.sockets = sockets
    self.refresher = refresher
    warmer = CacheWarmer(space: space, usage: usage)
    discoveryOwner = owner as? InProcessToolOwnerClient
    resolveModelExecutor = modelExecutorResolver(owner: owner)
    resolveModelGroup = modelGroupExecutorResolver(catalog: catalog)
    prepareModelRoute = modelRoutePreparer(catalog: catalog, usage: usage)
    budget = budgetResolver(owner: owner)
    firing = SubscriptionFiring(space: space, handler: handler)
    self.scripts = scripts
  }

  func configureDiscovery(contentHost: String? = nil, identity: (@Sendable () async throws -> JSONValue)? = nil) {
    scripts?.configureDiscovery(contentHost: contentHost, identity: identity)
    discoveryOwner?.configureScriptDiscovery(contentHost: contentHost, identity: identity)
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
      if let scripts { group.addTask { await scripts.run() } }
      if let sockets { group.addTask { await sockets.run() } }
      if let refresher {
        group.addTask { await refresher.run() }
      }
      await group.waitForAll()
    }
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
    executionPlacement: ExecutionPlacement = .inProcess,
  ) async -> SessionRuntime {
    await assemble(
      space: space, hub: hub, attemptLog: attemptLog, metrics: metrics, credentials: credentials,
      secrets: secrets, usage: UsageBoard(), executionPlacement: executionPlacement,
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
    executionPlacement: ExecutionPlacement = .inProcess,
    oidcToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    oidcReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
  ) async -> SessionRuntime {
    let attempts = AttemptHub()
    let executionOwner = InProcessExecutionOwnerClient(
      space: space, metrics: metrics, credentials: credentials, inferenceToken: oidcToken, inferenceReadiness: oidcReadiness, inferenceBindingIdentity: oidcBindingIdentity, attemptLog: attemptLog,
    )
    let executionCredentials = CredentialResolver.bound { try await executionOwner.providerCredentialBinding($0) }
    let executionMetrics = InferenceMetricsSink { await executionOwner.recordMetric($0) }
    let thresholds = CompactionThresholds()
    @Dependency(\.date) var date
    // Models are data in the space, edited at runtime (`wuhu models update`):
    // the catalog is re-read per use, never cached at boot.
    let catalogs: @Sendable (Bool) async throws -> ProviderCatalog = { includeGroups in
      let data = try await executionOwner.modelDocument()
      let groups = includeGroups ? try await executionOwner.modelGroupDocument() : nil
      return ProviderCatalog(
        document: try ModelsDocument(json: data, groupsJSON: groups),
        credentials: executionCredentials,
        oidcToken: { try await executionOwner.inferenceToken(audience: $0, session: $1) },
        oidcReadiness: { try await executionOwner.inferenceReadiness(audience: $0) },
        oidcBindingIdentity: { try await executionOwner.inferenceBindingIdentity(audience: $0, session: $1) },
        receiveCodexResponseHeaders: { providerID, headers in
          usage.record(providerID, plan: headers["x-codex-plan-type"], windows: codexUsage(headers: headers), at: date.now)
        },
      )
    }

    let catalog: @Sendable () async throws -> ProviderCatalog = { try await catalogs(true) }
    let providerCatalog: @Sendable () async throws -> ProviderCatalog = { try await catalogs(false) }
    let serviceSlot = SessionServiceSlot()
    let machines = machineSeam(hub: hub)
    let exec = execBackend(space: space, hub: hub)
    let owner: any WorkerOwnerClient = InProcessToolOwnerClient(
      space: space,
      executionOwner: executionOwner,
      secrets: secrets,
      identityFetch: identityFetch,
      machines: machines,
      exec: exec,
      scriptMachines: ScriptMachineAccess(files: machines, exec: exec),
      resolveModelExecutor: modelExecutorResolver(owner: executionOwner),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
      completionMetrics: executionMetrics,
      control: sessionControl { serviceSlot.service },
    )
    if let executable = executionPlacement.executable {
      let runtimeOwner = WorkerRuntimeOwner(attempts: attempts, scriptLost: lostWorkerScript(owner: owner), usage: { usage.snapshot() }, receiveUsage: { provider, value in
        usage.record(provider, plan: value.plan, windows: value.windows, at: Date(timeIntervalSince1970: value.observedAt))
      }, allowsWarming: { try await CacheWarmer(space: space, usage: usage).allows($0) }, scheduleReminder: { session, due in
        guard let service = serviceSlot.service else { throw SessionExecutionRetired() }
        await service.scheduleWake(session, at: due)
      }, scheduleWarming: { session, interval in
        try await space.sessions.scheduleCacheWarming(session, intervalSeconds: interval)
      })
      let execution = LazyExecutionWorker(executable: executable, sessions: space.sessions, owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtimeOwner, machines: true)
      let service = SessionService(sessions: space.sessions, execution: execution, archiveGrace: .seconds(24 * 3600))
      serviceSlot.bind(service)
      return SessionRuntime(
        space: space,
        service: service,
        attempts: attempts,
        usage: usage,
        sockets: nil,
        refresher: UsageRefresher(board: usage, space: space, credentials: credentials),
        scripts: nil,
        handler: execution,
        startup: { await Scripts.announceRestart(owner: owner) },
        owner: owner,
        catalog: catalog,
      )
    }
    let sockets = ResponsesSocketRegistry()
    let scripts = Scripts(owner: owner)
    scripts.configureDiscovery(toolRosters: sessionToolRosters())
    let budget = budgetResolver(owner: owner)
    let executor = ToolExecutor(
      owner: owner, credentials: executionCredentials,
      completionCatalog: catalog, scripts: scripts,
    )

    let config = LoopConfig(
      executeTool: { invocation in
        try await executor.execute(session: invocation.sessionID, call: invocation.call, state: invocation.state)
      },
      inference: kernelInference(
        owner: owner, catalog: providerCatalog, groupCatalog: catalog, sockets: sockets, attempts: attempts,
        usage: usage,
        committedWarming: { id, policy in
          do { try await space.sessions.scheduleCacheWarming(id, intervalSeconds: policy.intervalSeconds) }
          catch { Logger(label: "wuhu.cache-warmer").error("could not schedule cache warming", metadata: ["session": "\(id.rawValue)", "error": "\(error)"]) }
        },
      ),

      compact: { id, transcript in
        await mechanicalCompaction(of: transcript, images: budget(id).images)
      },
      budget: budget,
      prepareCompaction: compactionPlacement(owner: executionOwner, catalog: catalog, usage: usage),
      killInterruptedTool: { invocation in
        guard invocation.call.name == "exec" else { return }
        await owner.killInterruptedExec(
          session: invocation.sessionID, toolCallID: ToolCallID(invocation.call.id),
        )
      },
      invalidateInference: { await sockets.invalidate($0) },
      allowCacheWarming: { try await CacheWarmer(space: space, usage: usage).allows($0) },
      thresholds: thresholds,
    )

    let service = await SessionService(sessions: space.sessions, owner: owner, loopConfig: config)
    serviceSlot.bind(service)
    return SessionRuntime(
      space: space,
      service: service,
      attempts: attempts,
      usage: usage,
      sockets: sockets,
      refresher: UsageRefresher(board: usage, space: space, credentials: credentials),
      scripts: scripts,
      handler: ScriptHandlerExecutor(scripts: scripts, tools: executor),
      owner: owner, catalog: catalog,
    )
  }
}

func sessionToolExecutor(
  space: Space,
  hub: MachineHub,
  credentials: CredentialResolver,
  scripts: Scripts?,
  control: SessionControl?,
  completionCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
  completionMetrics: InferenceMetricsSink? = nil,
  usage: UsageBoard = UsageBoard(),
  resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
  prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
) -> ToolExecutor {
  let owner = InProcessExecutionOwnerClient(space: space, credentials: credentials)
  let catalog = completionCatalog ?? groupCatalog(owner: owner)
  return ToolExecutor(
    space: space,
    machines: machineSeam(hub: hub),
    exec: execBackend(space: space, hub: hub),
    resolveModelExecutor: modelExecutorResolver(owner: owner),
    resolveModelGroup: resolveModelGroup ?? modelGroupExecutorResolver(catalog: catalog),
    prepareModelRoute: prepareModelRoute ?? modelRoutePreparer(catalog: catalog, usage: usage),
    credentials: credentials,
    completionCatalog: completionCatalog,
    completionMetrics: completionMetrics,
    scripts: scripts,
    control: control,
  )
}

// The kernel's tool executor is built before the service that runs the
// loops, so its session verbs reach the service through this slot.
final class SessionServiceSlot: Sendable {
  private let slot = Mutex<SessionService?>(nil)

  func bind(_ service: SessionService) {
    slot.withLock { $0 = service }
  }

  var service: SessionService? {
    slot.withLock { $0 }
  }
}

func sessionControl(_ service: @escaping @Sendable () -> SessionService?) -> SessionControl {
  SessionControl { verb, id, force in
    guard let service = service() else {
      throw SessionControlRefusal("the session loops are not running yet")
    }
    do {
      switch verb {
      case .interrupt: try await service.interrupt(id)
      case .resume: try await service.resume(id)
      case .archive: try await service.archive(id, force: force)
      case .unarchive: try await service.unarchive(id)
      }
    } catch let busy as SubtreeArchiveBusy {
      throw SessionControlRefusal(busy.message, reason: busy.sessions.contains { $0.id == id } ? .busy : .other)
    } catch let SessionError.unreadableData(id) {
      throw SessionControlRefusal(SessionError.unreadableData(id).description)
    } catch SessionError.archiveInProgress {
      throw SessionControlRefusal("session \(id.rawValue) is being archived; retry after the archive finishes")
    } catch SessionError.archiveReservationLost {
      throw SessionControlRefusal("session \(id.rawValue) changed during archive; archive stopped, retry it")
    } catch SessionError.archiveGraceExpired {
      throw SessionControlRefusal("session \(id.rawValue) is archived and its grace has expired")
    }
  }
}

func execBackend(space: Space, hub: MachineHub) -> ExecBackend {
  ExecBackend(
    claim: { machine, session, callID in
      try await hub.requireExecKind(machine)
      let claim = try await space.claimExec(
        machine: machine,
        caller: session.rawValue,
        toolCallID: callID,
      )
      await hub.noteMinted(claim.record)
      return claim
    },
    connect: { id in
      guard let record = try await space.execRecord(id) else {
        throw MachineHubError.execNotFound(id)
      }
      let (server, client) = WebSocket.pair()
      // Bounded, not leaked: the hub session ends when the transport
      // closes its socket end (tool completion, cancellation, or kill).
      Task { await hub.runCallerSession(record, socket: server, leg: record.caller.map { .session(SessionID(rawValue: $0)) } ?? .anonymous) }
      return WebSocketTransport(client)
    },
    status: { try await space.execRecord($0) },
    mintScript: { machine, session, script in
      try await hub.requireExecKind(machine)
      let record = try await space.mintScriptExec(machine: machine, session: session.rawValue, script: script)
      await hub.noteMinted(record)
      return record
    },
    kill: { try await hub.kill($0) },
  )
}

func modelExecutorResolver(space: Space) -> @Sendable (String, String, String?) async throws -> SessionExecutor {
  modelExecutorResolver(owner: InProcessExecutionOwnerClient(space: space))
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
    case .cancelObservation: "cancel_observation"
    case .cancelTimer: "cancel_timer"
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
  try await systemPrompt(owner: InProcessExecutionOwnerClient(space: space), record: record)
}

private func machineOperationFailure(_ error: OperationError) -> ToolRunError {
  let code: ErrorCode = switch error.code {
  case .unknownKind: .unknownKind
  case .invalidInput, .invalidOffset, .inputTooLarge: .invalidArgument
  case .unsupportedDialect, .unsupportedProtocol: .unsupported
  case .machineNotAuthorized, .credentialExpired: .unauthorized
  case .fileChanged, .operationExists, .invocationConflict: .conflict
  case .unknownMachine: .notFound
  default: .unavailable
  }
  return .failed(code: code, message: "\(error.code.rawValue): \(error.message)", hint: nil)
}
