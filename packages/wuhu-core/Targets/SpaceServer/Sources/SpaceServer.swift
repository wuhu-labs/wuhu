#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import struct Credentials.CredentialsStore
import struct Credentials.SpaceSecretStores
import enum Credentials.UserConfig
import Dependencies
import Fetch
import struct InferenceKit.AttemptLogConfig
import struct InferenceKit.ModelsDocument
import JSONValue
import Logging
import MachineContract
import OrderedCollections
import Serve
import ServeNIO
import ServeRouting
import ServeTLS
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupID
import SpaceCore
import SpaceTools
import WebPush

public enum SpaceServer {
  public static let unstampedVersion: String = "0.0.0-unstamped"

  public static func handler(
    space: Space,
    hub: MachineHub,
    sessions: SessionRuntime? = nil,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    fingerprint: String? = nil,
    dev: Bool,
    version: String = SpaceServer.unstampedVersion,
    webApp: WebApp? = .embedded,
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
  ) -> UpgradingHandler {
    configuredHandler(
      space: space,
      hub: hub,
      sessions: sessions,
      origin: origin,
      contentHostPattern: contentHostPattern,
      fingerprint: fingerprint,
      dev: dev,
      version: version,
      webApp: webApp,
      webPushApplicationServerKey: nil,
      credentials: credentials,
      secrets: secrets,
    )
  }

  // The full handler: `serve()` wires the session tokens here, and so do the
  // package's tests.
  package static func configuredHandler(
    space: Space,
    hub: MachineHub,
    sessions: SessionRuntime? = nil,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    port: Int? = nil,
    fingerprint: String? = nil,
    dev: Bool,
    publicRead: Bool = false,
    version: String = SpaceServer.unstampedVersion,
    webApp: WebApp? = .embedded,
    views: ViewProviders? = .embedded,
    webPushApplicationServerKey: String? = nil,
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
    execTokens: ExecTokens? = nil,
  ) -> UpgradingHandler {
    let machines = machineSeam(hub: hub)
    // Without --origin, content lives under localhost at the listener's port.
    let localhost = "https://localhost" + (port.map { ":\($0)" } ?? "")
    let contentHost: ContentHost
    if let contentHostPattern {
      precondition(origin != nil, "a content host pattern requires an origin")
      contentHost = ContentHost(origin: origin!, pattern: contentHostPattern)!
    } else {
      contentHost = ContentHost(origin: origin ?? localhost) ?? ContentHost(origin: localhost)!
    }
    @Dependency(\.date) var clock
    let contextOf: @Sendable (Request) async throws -> ToolContextVerdict = { request in
      switch try await requestPrincipal(request, space: space, date: clock) {
      case let .principal(principal): .context(SpaceToolContext(space: space, machines: machines, principal: principal))
      case let .refused(response): .refused(response)
      }
    }
    var router = Router()
    router.post("/v1/tools/:name") { request, parameters in
      let name = parameters["name"] ?? ""
      guard let tool = SpaceToolbox.all.first(where: { $0.name == name }) else {
        return errorResponse(.notFound, code: "notFound", message: "unknown tool: \(name)")
      }
      let body = try await request.body?.text() ?? ""
      guard let input = JSONValue.parse(body) else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "request body is not valid JSON")
      }
      let context: SpaceToolContext
      switch try await contextOf(request) {
      case let .context(resolved): context = resolved
      case let .refused(response): return response
      }
      do {
        return jsonResponse(try await tool.run(context, input: input))
      } catch let error as ToolRunError {
        switch error {
        case .undecodableInput:
          return jsonResponse(error.payload, status: .badRequest)
        case .failed:
          return jsonResponse(error.payload, status: .unprocessableContent)
        }
      }
    }
    addFileRoutes(&router, contextOf: contextOf)
    addToolRosterRoutes(&router)
    router.get("/v1/observe") { request, _ in
      let principal: Principal
      switch try await requestPrincipal(request, space: space, date: clock) {
      case let .principal(resolved): principal = resolved
      case let .refused(response): return response
      }
      return await observeResponse(space: space, url: request.url, principal: principal) {
        @Dependency(\.date) var date
        return try await identityVerdict(
          queryValues(of: request.url)["identity"], request: request, space: space, dev: dev, now: date.now,
        )
      }
    }
    router.get("/v1/server") { request, _ in
      var info: OrderedDictionary<String, JSONValue> = [:]
      info["space"] = .string(try await space.identity().rawValue)
      info["origin"] = origin.map(JSONValue.string)
      if let pattern = contentHost.pattern {
        info["contentHost"] = .string(pattern.template)
      } else {
        info["contentBase"] = .string(contentHost.base)
      }
      info["features"] = .array([.string(GroupHeader.feature)])
      // Public discovery names the group asked for and checks nothing; the
      // routes that act in it do.
      info["group"] = .string(namedGroup(request).rawValue)
      return jsonResponse(.object(info))
    }
    addGroupRoutes(&router, space: space, dev: dev)
    addMachineRoutes(
      &router, space: space, hub: hub, challenges: OneShotChallenges(prefix: "mch_"), fingerprint: fingerprint,
    ) { request in
      try await requestPrincipal(request, space: space, date: clock)
    }
    addAuthRoutes(&router, space: space, challenges: OneShotChallenges(prefix: "slc_"), fingerprint: fingerprint, dev: dev)
    addAccountRoutes(&router, space: space, dev: dev)
    addDeviceRoutes(&router, space: space, dev: dev)
    addUserRoutes(&router, space: space, dev: dev)
    addProviderRoutes(&router, space: space, usage: sessions?.usage)
    addTranscribeRoutes(&router, space: space, credentials: credentials)
    addCapabilityRoutes(&router, space: space, credentials: credentials)
    addSecretRoutes(&router, space: space, secrets: secrets) { request in
      try await requestPrincipal(request, space: space, date: clock)
    }
    if let webPushApplicationServerKey {
      addWebPushRoutes(&router, space: space, applicationServerKey: webPushApplicationServerKey)
    }
    addPushRelayRoutes(&router, space: space, allowedHosts: pushRelayHosts(ProcessInfo.processInfo.environment))
    if let sessions {
      addSessionRoutes(&router, space: space, runtime: sessions, dev: dev) { request in
        try await requestPrincipal(request, space: space, date: clock)
      }
      addSessionLogRoutes(&router, space: space, runtime: sessions) { request in
        try await requestPrincipal(request, space: space, date: clock)
      }
      addMcpRoutes(
        &router, space: space, hub: hub, credentials: credentials, version: version, dev: dev, scripts: sessions.scripts,
        control: sessionControl { sessions.service },
      )
    }
    if let webApp {
      router.get("/*") { request, _ in
        webAppResponse(webApp, request: request, contentHostPattern: contentHost.pattern)
      }
    }
    let routed = router.upgradingHandler
    // A session's exec token is its own credential, in dev as behind the wall:
    // the session gate takes every request carrying one and passes the rest on.
    let gated: (@escaping UpgradingHandler) -> UpgradingHandler = { walled in
      guard let execTokens, let sessions else { return walled }
      return sessionGate(
        space: space, hub: hub, runtime: sessions, tokens: execTokens, credentials: credentials,
        routed: routed, otherwise: walled,
      )
    }
    let content = contentHandler(
      space: space, contentHost: contentHost, advertisedOrigin: origin, dev: dev, publicRead: publicRead, views: views,
    )
    if dev { return hostRouted(contentHost, api: gated(routed), content: content) }
    @Dependency(\.date) var dateGen
    // The wall. Exceptions carry their own credential and so must precede it:
    // machine connect and enroll share-login (each with the challenge mint
    // feeding it) authenticate by a signature over a one-shot challenge,
    // enroll consume by the join token it is about to burn, and the embedded
    // SPA's static GETs are trusted product chrome. Server info and the group
    // list are public discovery — the space id is a claim, not a secret, and a
    // wallet must read it from an address it cannot yet authenticate through. Everything
    // else needs a verified assertion. The content origin has its own wall
    // (readWall in WebOrigin.swift); --public-read opens that one only,
    // never this one.
    let selfAuthenticating: Set<String> = [
      "/v1/machine/connect", "/v1/machine/challenge",
      "/v1/enroll/consume",
      "/v1/enroll/share-login", "/v1/enroll/share-login/challenge",
      "/v1/server", "/v1/groups",
    ]
    return hostRouted(contentHost, api: gated { request in
      if selfAuthenticating.contains(request.url.path) {
        return try await routed(request)
      }
      if webApp != nil, request.method == .get, !isAPIPath(request.url) {
        return try await routed(request)
      }
      switch try await bearerVerdict(request: request, space: space, now: dateGen.now) {
      case .verified:
        return try await routed(request)
      case let .rejected(response):
        return .response(response)
      case .anonymous:
        return .response(errorResponse(
          .unauthorized,
          code: "unauthorized",
          message: "this space admits enrolled devices only",
          hint: "enroll this device (wuhu login < invite-link), or run the server with --dev",
        ))
      }
    }, content: content)
  }

  static func contentHandler(
    space: Space,
    contentHost: ContentHost,
    advertisedOrigin: String?,
    dev: Bool,
    publicRead: Bool,
    views: ViewProviders?,
  ) -> @Sendable (GroupID, Request) async throws -> Response {
    @Dependency(\.date) var dateGen
    // Forcing the embed here fails at bind time, not on the first request.
    let shell = ShellSDK.embedded
    return { group, request in
      try await webResponse(
        space: space,
        group: group,
        contentHost: contentHost,
        advertisedOrigin: advertisedOrigin,
        now: dateGen.now,
        dev: dev,
        publicRead: publicRead,
        views: views,
        shell: shell,
        request: request,
      )
    }
  }

  public static func serve(
    folder: URL,
    host: String = "127.0.0.1",
    port: Int,
    origin: URL? = nil,
    dev: Bool,
    version: String = SpaceServer.unstampedVersion,
    publicRead: Bool = false,
    devImport: URL? = nil,
    devExport: URL? = nil,
    certificate: URL? = nil,
    privateKey: URL? = nil,
    contentHostPattern: String? = nil,
    groupCertificate: URL? = nil,
    groupPrivateKey: URL? = nil,
    webAppDirectory: URL? = nil,
    hooks: ServeNIOHooks = ServeNIOHooks(),
  ) async throws {
    if let contentHostPattern {
      guard groupCertificate == nil, groupPrivateKey == nil else { throw ContentHostPatternError.groupCertificate }
      guard let origin, ContentHost(origin: origin.absoluteString, pattern: contentHostPattern) != nil else {
        throw ContentHostPatternError.invalid
      }
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Group hosts `<g>.<host>` get the group identity (a `*.<host>` leaf); the
    // bare host and every other name keep `identity`.
    let groupIdentity: TLSIdentity?
    switch (groupCertificate, groupPrivateKey) {
    case (nil, nil):
      groupIdentity = nil
    case let (groupPEM?, groupKey?):
      guard origin != nil else { throw GroupTLSError.noOrigin }
      // Invites pin the generated certificate, so it must be the one every
      // host serves.
      guard certificate != nil, privateKey != nil else { throw GroupTLSError.noCertificate }
      let loaded = try pemIdentity(certificate: groupPEM, privateKey: groupKey)
      // The TLS stack takes some identities it can't handshake with, and every
      // group host would then fail with alert 80: refuse to start instead.
      do {
        try loaded.validate()
      } catch {
        throw GroupTLSError.unusable(certificate: groupPEM.path, reason: "\(error)")
      }
      groupIdentity = loaded
    default:
      throw GroupTLSError.unpaired
    }
    let (identity, certificateKind) = try await tlsIdentity(folder: folder, certificate: certificate, privateKey: privateKey)
    func groupHosts(_ origin: String?) -> [String: TLSIdentity] {
      guard let groupIdentity, let host = origin.flatMap({ ContentHost(origin: $0) })?.host else { return [:] }
      return [host: groupIdentity]
    }
    let fingerprint = try identity.fingerprint()
    let logger = Logger(label: "wuhu.serve")
    logger.notice("TLS certificate fingerprint: \(fingerprint)")
    let advertisedOrigin = origin.map(normalizedOrigin)
    // Apple's push service rejects VAPID subjects that are not public https/mailto
    // contacts, so the contact must never derive from --origin (LAN or localhost hosts).
    let vapid = try await WebPushKeyStore.loadOrCreate(
      directory: folder.appendingPathComponent("web-push"),
      contact: URL(string: "https://wuhu.ai")!,
    )
    let webPushManager = WebPushManager(
      vapidConfiguration: vapid,
      networkConfiguration: .init(retryIntervals: []),
      backgroundActivityLogger: logger,
    )
    let webApp: WebApp?
    if let webAppDirectory {
      let loaded = try WebApp.load(directory: webAppDirectory)
      logger.notice("web app override: \(webAppDirectory.path) (\(loaded.files.count) files)")
      webApp = loaded
    } else {
      webApp = .embedded
    }
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    try await space.reindexLinks()
    let deployment = DeploymentRecord(origin: advertisedOrigin, tlsFingerprint: fingerprint, certificate: certificateKind)
    try await space.recordDeployment(deployment)
    if let devImport {
      try await space.importFolder(devImport)
    }
    let execTokens = ExecTokens(spaceURL: advertisedOrigin ?? "https://\(host):\(port)")
    let secrets = try await secretStore(space: space, logger: logger)
    let hub = MachineHub(space: space, tokens: execTokens, secrets: secrets)
    let metricsWriter = InferenceMetricsWriter(folder: folder, logger: logger)
    let credentials = try await credentialResolver(space: space, logger: logger)
    let usage = UsageBoard()
    let claudeCode = ClaudeCodeHost(
      space: space,
      credentials: credentials,
      usage: usage,
      configDirectory: try? UserConfig.directory(environment: ProcessInfo.processInfo.environment),
      origin: advertisedOrigin ?? "https://\(host):\(port)",
      spaceID: try await space.identity().rawValue,
    )
    if preinstallClaude(flatHosts: contentHostPattern != nil, models: await modelsDocument(space: space)) {
      claudeCode.installInBackground()
    }
    let sessions = await SessionRuntime.assemble(
      space: space,
      hub: hub,
      attemptLog: attemptLogConfig(),
      metrics: inferenceMetricsSink(space: space, writer: metricsWriter, logger: logger),
      credentials: credentials,
      secrets: secrets,
      claudeCode: claudeCode.seam,
      usage: usage,
      probeClaude: { await claudeCode.probeUsage(provider: $0) },
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
    // Machine frames carry up to a full flow-control window (4 MiB raw) or a
    // whole VFS read as base64 JSON; the 1 MiB wuhu-serve default would sever
    // real-socket machine channels. See SPEC.md "Frame size bound".
    var options = ServeOptions()
    options.maximumWebSocketFrameBytes = MachineHub.maximumFrameBytes
    options.maximumBodyBytes = maximumPostBodyBytes
    let api = try await ServeNIOServer.bind(
      host: host, port: port, tls: identity, subdomains: groupHosts(advertisedOrigin), options: options, hooks: hooks,
      upgrading: configuredHandler(
        space: space,
        hub: hub,
        sessions: sessions,
        origin: advertisedOrigin,
        contentHostPattern: contentHostPattern,
        port: port,
        fingerprint: deployment.pin,
        dev: dev,
        publicRead: publicRead,
        version: version,
        webApp: webApp,
        webPushApplicationServerKey: webPushManager.nextVAPIDKeyID.description,
        credentials: credentials,
        secrets: secrets,
        execTokens: execTokens,
      ),
    )
    let loopback: ServeNIOServer
    do {
      loopback = try await ServeNIOServer.bind(
        host: "127.0.0.1",
        port: 0,
        options: options,
        handler: claudeCodeLoopbackHandler(
          space: space, hub: hub, credentials: credentials, version: version,
          host: claudeCode, service: sessions.service, scripts: sessions.scripts,
        ),
      )
    } catch {
      await api.shutdown()
      throw error
    }
    guard let loopbackPort = loopback.boundAddress.port else { preconditionFailure("a TCP listener has a port") }
    claudeCode.serveLoopback(on: "http://127.0.0.1:\(loopbackPort)")
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var dateGen
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await hub.run() }
      group.addTask { await sessions.run() }
      group.addTask { await webPushRuntime.run() }
      group.addTask { await pushRelayRuntime.run() }
      group.addTask {
        do {
          try await webPushManager.run()
        } catch is CancellationError {
        } catch {
          logger.error("web push transport stopped", metadata: ["error": "\(error)"])
        }
      }
      group.addTask { await api.runUntilCancelled() }
      group.addTask { await loopback.runUntilCancelled() }
      await group.waitForAll()
    }
    await metricsWriter.close()
    if let devExport {
      // Graceful shutdown reaches here with serve()'s task already cancelled;
      // an unstructured task shields the export from GRDB's cancellation check.
      let export = Task { try await space.exportFolder(devExport) }
      try await export.value
    }
  }
}

/// One listener, two planes: the bare host is the API and the web app,
/// `<group>.<host>` that group's content.
func hostRouted(
  _ contentHost: ContentHost,
  api: @escaping UpgradingHandler,
  content: @escaping @Sendable (GroupID, Request) async throws -> Response,
) -> UpgradingHandler {
  { request in
    switch contentHost.plane(of: request.url.host) {
    case .api: try await api(request)
    case let .content(group): .response(try await content(group, request))
    case .misdirected: .response(plainStatus(.misdirectedRequest))
    }
  }
}

private func normalizedOrigin(_ origin: URL) -> String {
  let raw = origin.absoluteString
  return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
}

private func tlsIdentity(
  folder: URL, certificate: URL?, privateKey: URL?,
) async throws -> (TLSIdentity, DeploymentRecord.Certificate) {
  if let certificate, let privateKey {
    return (try pemIdentity(certificate: certificate, privateKey: privateKey), .provided)
  }
  let generated = try await TLSIdentity.loadOrCreate(
    directory: folder.appendingPathComponent("tls"),
    hosts: ["localhost", "*.localhost", "127.0.0.1", "::1"],
  )
  return (generated, .generated)
}

private func pemIdentity(certificate: URL, privateKey: URL) throws -> TLSIdentity {
  TLSIdentity(
    certificatePEM: String(decoding: try Data(contentsOf: certificate), as: UTF8.self),
    privateKeyPEM: String(decoding: try Data(contentsOf: privateKey), as: UTF8.self),
  )
}

public enum ContentHostPatternError: Error, Equatable {
  case invalid
  case groupCertificate
}

public enum GroupTLSError: Error, Equatable, CustomStringConvertible {
  case unpaired
  case noOrigin
  case noCertificate
  case unusable(certificate: String, reason: String)

  public var description: String {
    switch self {
    case .unpaired: "a group certificate and its private key go together"
    case .noOrigin: "a group certificate needs --origin: group hosts are named under its host"
    case .noCertificate:
      "a group certificate needs --cert/--key: invites pin the generated certificate, which must serve every host"
    case let .unusable(certificate, reason): "the group certificate \(certificate) can't serve TLS: \(reason)"
    }
  }
}

// Environment keys stay authoritative (CredentialResolver.live checks them
// first); the store only adds the per-space file under ~/.wuhu/credentials.
private func credentialResolver(space: Space, logger: Logger) async throws -> CredentialResolver {
  let identity = try await space.identity()
  do {
    let directory = try UserConfig.directory(environment: ProcessInfo.processInfo.environment)
    return .live(store: CredentialsStore(configDirectory: directory, spaceID: identity.rawValue))
  } catch {
    logger.warning("credential store unavailable (\(error)); provider keys resolve from environment only")
    return .environmentOnly
  }
}

private func secretStore(space: Space, logger: Logger) async throws -> SpaceSecretStores? {
  let directory: URL
  do {
    directory = try UserConfig.directory(environment: ProcessInfo.processInfo.environment)
  } catch {
    logger.warning("secret store unavailable (\(error)); scripts, execs and wuhu secret refuse secrets")
    return nil
  }
  return try secretStores(configDirectory: directory, spaceID: try await space.identity().rawValue)
}

/// The per-group secret stores, refused while the single file from before
/// groups is still in place: serving then would show every group no secrets.
/// A store folder looser than owner-only is tightened to 0700.
func secretStores(configDirectory: URL, spaceID: String) throws -> SpaceSecretStores {
  let stores = SpaceSecretStores(configDirectory: configDirectory, spaceID: spaceID)
  guard !stores.needsMove else { throw SecretsLayoutError.needsSecretsMove(stores.flatFile) }
  try stores.tightenDirectory()
  return stores
}

enum SecretsLayoutError: Error, Equatable, CustomStringConvertible {
  case needsSecretsMove(URL)

  var description: String {
    switch self {
    case let .needsSecretsMove(flat):
      let folder = flat.deletingPathExtension()
      return """
      needsSecretsMove: \(flat.path) holds this space's secrets from before groups; move it into the shared group, \
      then start again: mkdir -m 700 \(folder.path) && mv \(flat.path) \(folder.appendingPathComponent("shared.json").path)
      """
    }
  }
}

// The one attempt-logging toggle: set WUHU_ATTEMPT_LOG_DIR to a directory to
// capture one raw request/SSE file per inference attempt.
private func attemptLogConfig() -> AttemptLogConfig? {
  guard let directory = ProcessInfo.processInfo.environment["WUHU_ATTEMPT_LOG_DIR"], !directory.isEmpty else {
    return nil
  }
  return AttemptLogConfig(directory: URL(fileURLWithPath: directory, isDirectory: true))
}

func toolFailure(_ error: MachineHubError, machine: MachineID) -> ToolRunError {
  switch error {
  case .frameTooLarge:
    .failed(code: .invalidArgument, message: "request for machine \(machine.rawValue) exceeds the 16 MiB frame ceiling", hint: nil)
  case .machineLost:
    .failed(code: .unavailable, message: "machine \(machine.rawValue) stopped responding", hint: nil)
  case .machineUnattached, .execNotFound, .severed:
    .failed(code: .unavailable, message: "machine not attached: \(machine.rawValue)", hint: nil)
  }
}

func preinstallClaude(flatHosts: Bool, models: InferenceKit.ModelsDocument?) -> Bool {
  !flatHosts || models?.providers.values.contains(where: { $0.dialect == .claude }) == true
}
