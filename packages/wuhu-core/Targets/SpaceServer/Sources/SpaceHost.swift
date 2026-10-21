import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import struct Credentials.CredentialResolver
import struct Credentials.CredentialsStore
import Dependencies
import Fetch
import Logging
import struct OperationClient.OperationOwner
import Serve
import struct SessionDomain.SessionID
import struct SpaceContract.AIDisclosure
import SpaceCore
import WebPush
import struct WuhuVFS.DiskVFSNode
import struct WuhuVFS.NodeTreeVFS

public actor SpaceHost {
  public nonisolated let space: Space
  public nonisolated let id: String
  public nonisolated let handler: UpgradingHandler
  nonisolated let credentials: CredentialResolver
  private let taskScope = TaskScope()
  private var runTask: Task<Void, Never>?
  private let sockets: HostSockets
  private let requests: HostRequests
  private var stopped = false
  private var shutdownTask: Task<Void, Error>?
  private let runBody: @Sendable () async -> Void
  private let shutdownBody: @Sendable (_ handingOver: Bool) async throws -> Void
  /// The worker processes, when the workers run out of process.
  nonisolated let processWorkers: ProcessWorkers?
  nonisolated let sessions: SessionRuntime?
  nonisolated let execTokens: ExecTokens?

  public static func loadDisclosure(from file: URL) async throws -> AIDisclosure {
    try await loadAIDisclosure(
      from: NodeTreeVFS(root: DiskVFSNode(path: file.deletingLastPathComponent().path, isMutable: false)),
      path: "/" + file.lastPathComponent, file: file.path,
    )
  }

  public static func open(
    folder: URL, deployment: DeploymentRecord, configDirectory: URL?,
    allowEnvironmentCredentials: Bool = true, fallbackOrigin: String = "https://localhost", port: Int? = nil,
    dev: Bool = false, publicRead: Bool = false,
    contentHostPattern: String? = nil, aiDisclosure: AIDisclosure? = nil,
    version: String = SpaceServer.unstampedVersion, webContent: WebContent = WebContent(),
    devImport: URL? = nil, devExport: URL? = nil,
  ) async throws -> SpaceHost {
    try await open(
      folder: folder, deployment: deployment, configDirectory: configDirectory, allowEnvironmentCredentials: allowEnvironmentCredentials,
      fallbackOrigin: fallbackOrigin, port: port, dev: dev, publicRead: publicRead, contentHostPattern: contentHostPattern,
      aiDisclosure: aiDisclosure, version: version, webContent: webContent, devImport: devImport, devExport: devExport, placement: .inProcess,
    )
  }

  static func open(
    folder: URL, deployment: DeploymentRecord, configDirectory: URL?,
    allowEnvironmentCredentials: Bool, fallbackOrigin: String, port: Int?, dev: Bool, publicRead: Bool,
    contentHostPattern: String?, aiDisclosure: AIDisclosure?, version: String, webContent: WebContent,
    devImport: URL?, devExport: URL?, placement: WorkerPlacement,
  ) async throws -> SpaceHost {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    let id = try await space.identity().rawValue
    return try await SpaceLogContext.$spaceID.withValue(id) {
      let advertisedOrigin = deployment.origin
      let logger = Logger(label: "wuhu.serve")
      let identityDirectory = folder.appendingPathComponent("identity")
      let serverKey = try await ServerIdentity.loadOrCreate(directory: identityDirectory)
      @Dependency(\.fetch) var identityFetch
      let serverIdentity = try await IdentityController.load(identity: serverKey, origin: advertisedOrigin, store: .disk(identityDirectory), fetch: identityFetch)
      // Apple's push service rejects VAPID subjects that are not public https/mailto
      // contacts, so the contact must never derive from --origin (LAN or localhost hosts).
      let vapid = try await WebPushKeyStore.loadOrCreate(
        directory: folder.appendingPathComponent("web-push"),
        contact: URL(string: "https://wuhu.ai")!,
      )
      let handover: Handover?
      if case let .process(_, _, taken) = placement { handover = taken } else { handover = nil }
      try await space.reindexLinks()
      try await space.recordDeployment(deployment)
      if let devImport, handover == nil {
        try await space.importFolder(devImport)
      }
      let execTokens = ExecTokens(spaceURL: advertisedOrigin ?? fallbackOrigin)
      let secrets = try configDirectory.map { try secretStores(configDirectory: $0, spaceID: id) }
      let hub = MachineHub(space: space, tokens: execTokens, secrets: secrets)
      let v2Hub = MachineV2Hub(space: space)
      let v2Service = await MachineV2Service.open(space: space, hub: v2Hub, directory: folder.appendingPathComponent("machine-v2"))
      await hub.configureV2(v2Service)
      let metricsWriter = InferenceMetricsWriter(folder: folder, logger: logger)
      let credentials = configDirectory.map { CredentialResolver.live(store: CredentialsStore(configDirectory: $0, spaceID: id), allowEnvironment: allowEnvironmentCredentials) } ?? (allowEnvironmentCredentials ? .environmentOnly : .unavailable)
      let usage = UsageBoard()
      let sessions = await SessionRuntime.assemble(
        space: space,
        hub: hub,
        attemptLog: attemptLogConfig(),
        metrics: inferenceMetricsSink(space: space, writer: metricsWriter, logger: logger),
        credentials: credentials,
        secrets: secrets,
        usage: usage,
        tokens: execTokens,
        oidcToken: { audience, session in
          @Dependency(\.date) var date
          @Dependency(\.uuid) var uuid
          let record = try await space.sessions.record(session)
          return try await serverIdentity.tokenForInference(audience: audience, space: space.identity().rawValue, group: record.group.rawValue, session: session.rawValue, now: date.now, id: uuid())
        },
        oidcReadiness: { audience in
          @Dependency(\.date) var date
          @Dependency(\.uuid) var uuid
          _ = try await serverIdentity.tokenForInference(audience: audience, space: space.identity().rawValue, group: "shared", session: "model-group-readiness", now: date.now, id: uuid())
        },
        oidcBindingIdentity: { audience, session in
          let record = try await space.sessions.record(session)
          return try await serverIdentity.inferenceReplayIdentity(audience: audience, space: space.identity().rawValue, group: record.group.rawValue)
        },
        outOfProcess: placement.outOfProcess,
        takingOver: handover != nil,
      )
      let processWorkers: ProcessWorkers? = if case let .process(executable, socket, _) = placement {
        ProcessWorkers(
          registry: sessions.workers, executable: executable, socket: socket, spaceID: id, environment: ProcessInfo.processInfo.environment,
        )
      } else { nil }
      if let handover {
        execTokens.restore(handover.tokens) { key in v2Service.credentialActive(group: key.group, owner: OperationOwner(scope: key.scope, key: key.key)) }
        sessions.workers.restore(mintedCount: handover.minted)
        processWorkers?.adopt(handover.workers)
        for (session, due) in handover.wakes { await sessions.service.scheduleWake(SessionID(session), at: Date(timeIntervalSince1970: due)) }
      }
      var pushConfiguration = HTTPClient.Configuration()
      pushConfiguration.httpVersion = .automatic
      pushConfiguration.timeout.connect = .seconds(10)
      pushConfiguration.timeout.read = nil
      pushConfiguration.timeout.write = nil
      pushConfiguration.connectionPool.idleTimeout = .hours(12)
      let webPushHTTPClient = HTTPClient(configuration: pushConfiguration, backgroundActivityLogger: logger)
      let webPushManager = WebPushManager(
        vapidConfiguration: vapid,
        networkConfiguration: .init(retryIntervals: []),
        backgroundActivityLogger: logger,
        unsafeHTTPClient: webPushHTTPClient,
      )
      let webPushRuntime = WebPushRuntime(
        space: space,
        logger: logger,
        client: .live(manager: webPushManager, logger: logger),
      )
      @Dependency(\.fetch) var fetch
      let pushRelayRuntime = PushRelayRuntime(
        space: space,
        logger: logger,
        client: .live(fetch: fetch),
      )
      let keyStreams = KeyStreams()
      @Dependency(\.continuousClock) var releaseClock
      let releases = MachineV2Releases(base: URL(string: "https://wuhu.ai")!, fetch: fetch, clock: releaseClock)
      let handler = SpaceServer.configuredHandler(
        space: space,
        hub: hub,
        sessions: sessions,
        origin: advertisedOrigin,
        contentHostPattern: contentHostPattern,
        aiDisclosure: aiDisclosure,
        port: port,
        fingerprint: deployment.pin,
        dev: dev,
        publicRead: publicRead,
        version: version,
        webContent: webContent,
        webPushApplicationServerKey: webPushManager.nextVAPIDKeyID.description,
        credentials: credentials,
        secrets: secrets,
        execTokens: execTokens,
        identityController: serverIdentity,
        machineV2Hub: v2Hub,
        machineV2Releases: releases,
        keyStreams: keyStreams,
        pageFetch: PageFetch(controller: serverIdentity).response,
      )
      let sockets = HostSockets()
      let requests = HostRequests()
      let scoped = spaceScopedHandler(id: id, handler: handler)
      let owned = spaceOwnedHandler(handler: scoped, requests: requests, sockets: sockets)
      return SpaceHost(space: space, id: id, credentials: credentials, sockets: sockets, requests: requests, handler: owned, processWorkers: processWorkers, sessions: sessions, execTokens: execTokens, runBody: {
        do { try processWorkers?.start() } catch { logger.error("could not start a worker", metadata: ["error": "\(error)"]) }
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await serverIdentity.run() }
          group.addTask { await hub.run() }
          group.addTask {
            do { try await v2Service.run() }
            catch is CancellationError {}
            catch { logger.error("Machine v2 coordinator stopped", metadata: ["error": "\(error)"]) }
          }
          group.addTask { await sessions.run() }
          group.addTask { await webPushRuntime.run() }
          group.addTask { await pushRelayRuntime.run() }
          await group.waitForAll()
        }
      }, shutdownBody: { handingOver in
        await keyStreams.close()
        await releases.close()
        await v2Service.shutdown()
        // Handing over, main has already let go of its workers: they run on.
        await sessions.service.shutdown()
        if !handingOver { await processWorkers?.stop() }
        await metricsWriter.close()
        var failure: (any Error)?
        if let devExport, !handingOver {
          do {
            try await uncancellable("Export the space after serve has been cancelled") { try await space.exportFolder(devExport) }
          } catch { failure = error }
        }
        do { try await space.close() } catch { if failure == nil { failure = error } }
        do { try await webPushHTTPClient.shutdown() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
      })
    }
  }

  private init(
    space: Space, id: String, credentials: CredentialResolver, sockets: HostSockets, requests: HostRequests, handler: @escaping UpgradingHandler,
    processWorkers: ProcessWorkers? = nil, sessions: SessionRuntime? = nil, execTokens: ExecTokens? = nil,
    runBody: @escaping @Sendable () async -> Void, shutdownBody: @escaping @Sendable (Bool) async throws -> Void,
  ) {
    self.processWorkers = processWorkers
    self.sessions = sessions
    self.execTokens = execTokens
    self.space = space
    self.id = id
    self.credentials = credentials
    self.sockets = sockets
    self.requests = requests
    self.handler = handler
    self.runBody = runBody
    self.shutdownBody = shutdownBody
  }

  public func run() async {
    guard !stopped else { return }
    if runTask == nil {
      runTask = try? taskScope.run("space-services") { await SpaceLogContext.$spaceID.withValue(id) { await runBody() } }
    }
    guard let task = runTask else { return }
    await withTaskCancellationHandler {
      await task.value
    } onCancel: { task.cancel() }
  }

  public func shutdown() async throws {
    try await shutdown(handingOver: false)
  }

  /// What the worker socket serves: main's API, as this host owns its requests.
  nonisolated var workerHandler: UpgradingHandler? {
    guard let sessions else { return nil }
    let api = sessions.api
    return spaceOwnedHandler(handler: spaceScopedHandler(id: id) { try await api($0) }, requests: requests, sockets: sockets)
  }

  /// Puts new workers up and moves every session to them; the old workers exit.
  func rollWorkers() async throws {
    try await processWorkers?.roll()
  }

  /// Stops this main for the one it `execve`s into, and returns what that one
  /// takes over. The workers run on, held by nobody until they announce to it.
  func handOver() async throws -> Handover {
    guard let sessions, let execTokens else { preconditionFailure("only a host with sessions hands over") }
    await requests.quiesce(grace: .seconds(5))
    let wakes = await sessions.service.scheduledWakes()
    sessions.workers.detach()
    try await shutdown(handingOver: true)
    return Handover(
      tokens: execTokens.table(), minted: sessions.workers.mintedCount, workers: processWorkers?.children ?? [],
      wakes: Dictionary(uniqueKeysWithValues: wakes.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
    )
  }

  private func shutdown(handingOver: Bool) async throws {
    if let shutdownTask { return try await shutdownTask.value }
    stopped = true
    // Out of process, the workers are told to stop while their lines are
    // still open; a main handing over leaves them running.
    if !handingOver, processWorkers != nil { await sessions?.workers.shutdown() }
    let background = runTask
    background?.cancel()
    // Shutdown must finish even if its first caller is cancelled.
    let shutdown = try taskScope.run("space-shutdown") {
      await requests.shutdown(sockets: sockets)
      await background?.value
      try await SpaceLogContext.$spaceID.withValue(id) { try await shutdownBody(handingOver) }
    }
    shutdownTask = shutdown
    let result = await shutdown.result
    await taskScope.close()
    try result.get()
  }
}

func spaceScopedHandler(id: String, handler: @escaping UpgradingHandler) -> UpgradingHandler {
  { request in
    let result = try await SpaceLogContext.$spaceID.withValue(id) { try await handler(request) }
    switch result {
    case .response: return result
    case let .boundedWebSocket(limits, subprotocol, session):
      return .boundedWebSocket(limits: limits, subprotocol: subprotocol) { transport in
        await SpaceLogContext.$spaceID.withValue(id) { await session(transport) }
      }
    case let .webSocket(session):
      return .webSocket { socket in
        await SpaceLogContext.$spaceID.withValue(id) { await session(socket) }
      }
    }
  }
}

func spaceOwnedHandler(handler: @escaping UpgradingHandler, requests: HostRequests, sockets: HostSockets) -> UpgradingHandler {
  { request in
    switch try await requests.run(handler, request: request) {
    case let .response(response): return .response(response)
    case let .boundedWebSocket(limits, subprotocol, session):
      return .boundedWebSocket(limits: limits, subprotocol: subprotocol) { transport in
        await sockets.run({ await session(transport) }, abort: transport.abort)
      }
    case let .webSocket(session):
      return .webSocket { socket in await sockets.run(session, socket: socket) }
    }
  }
}

/// Where a space's workers run: in main's process, or each in a process of
/// its own started from `executable`, reaching main over `socket`.
enum WorkerPlacement: Sendable {
  case inProcess
  /// `handover` is what the main this one took over from left.
  case process(executable: String, socket: String, handover: Handover?)

  var outOfProcess: Bool { if case .process = self { true } else { false } }
}
