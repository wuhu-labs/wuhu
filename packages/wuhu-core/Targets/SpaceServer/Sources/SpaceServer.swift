#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import ContentLane
import struct Credentials.CredentialResolver
import struct Credentials.CredentialsStore
import struct Credentials.SpaceSecretStores
import enum Credentials.UserConfig
import Dependencies
import struct ExecutionOwner.AttemptLogConfig
import Fetch
import JSONValue
import JSXCompile
import Logging
import MachineChannel
import MachineContract
import class MainHub.Hub
import struct ModelProviders.ModelsDocument
import NIOCore
import OrderedCollections
import Serve
import ServeNIO
import ServeRouting
import ServeTLS
import SpaceClient
import struct SpaceContract.AIDisclosure
import enum SpaceContract.ErrorCode
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupID
import enum SpaceContract.LiveChannel
import SpaceCore
import SpaceTools
import WebPush
import Wuwei

public enum SpaceServer {
  public static let unstampedVersion: String = "0.0.0-unstamped"

  public static func handler(
    space: Space,
    hub: MachineHub,
    sessions: SessionRuntime? = nil,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    aiDisclosure: AIDisclosure? = nil,
    fingerprint: String? = nil,
    devPerson: ResolvedPerson?,
    version: String = SpaceServer.unstampedVersion,
    webContent: WebContent = WebContent(),
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
  ) -> UpgradingHandler {
    configuredHandler(
      space: space,
      hub: hub,
      sessions: sessions,
      origin: origin,
      contentHostPattern: contentHostPattern,
      aiDisclosure: aiDisclosure,
      fingerprint: fingerprint,
      devPerson: devPerson,
      version: version,
      webContent: webContent,
      webPushApplicationServerKey: nil,
      credentials: credentials,
      secrets: secrets,
    )
  }

  // The full handler: `serve()` wires the session tokens here, and so do the
  // package's tests.
  static func configuredHandler(
    space: Space,
    hub: MachineHub,
    sessions: SessionRuntime? = nil,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    aiDisclosure: AIDisclosure? = nil,
    port: Int? = nil,
    fingerprint: String? = nil,
    devPerson: ResolvedPerson?,
    publicRead: Bool = false,
    version: String = SpaceServer.unstampedVersion,
    webContent: WebContent = WebContent(),
    webPushApplicationServerKey: String? = nil,
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
    execTokens: ExecTokens? = nil,
    identityController: IdentityController? = nil,
    listenerRoutes: Router = Router(),
    keyStreams: KeyStreams = KeyStreams(),
    pageFetch: (@Sendable (Request, Set<String>, String, String, String, String, NIODeadline) async throws -> Response)? = nil,
    machines: MachineSeam? = nil,
  ) -> UpgradingHandler {
    let machines = machines ?? machineSeam(hub: hub)
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
      switch try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock) {
      case let .principal(principal): .context(SpaceToolContext(space: space, machines: machines, principal: principal))
      case let .refused(response): .refused(response)
      }
    }
    var router = listenerRoutes
    for path in ["/.well-known/openid-configuration", "/.well-known/jwks.json"] {
      router.get(path) { _, _ in
        let keys: JSONValue?
        do { keys = try await identityController?.jwks }
        catch { return errorResponse(.unprocessableContent, code: "oidcConfiguration", message: "The server identity key is unavailable.") }
        guard let issuer = try? ServerIdentity.issuer(origin), let keys else {
          return errorResponse(.unprocessableContent, code: "oidcConfiguration", message: "OIDC requires a server identity key and a configured HTTPS --origin.")
        }
        if path == "/.well-known/jwks.json" { return jsonResponse(keys) }
        return jsonResponse(.object([
          "issuer": .string(issuer), "jwks_uri": .string(issuer + "/.well-known/jwks.json"),
          "id_token_signing_alg_values_supported": .array([.string("ES256")]),
        ]))
      }
    }
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
        case .evicted:
          throw EvictedRefusal()
        }
      }
    }
    addFileRoutes(&router, compiler: JSXCompiler(), contextOf: contextOf)
    addLiveRoutes(&router, space: space, keyStreams: keyStreams, devPerson: devPerson, contextOf: contextOf)
    router.post("/v1/fetch") { request, _ in
      switch try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock) {
      case let .principal(principal): await widgetFetchResponse(space: space, principal: principal, proxy: pageFetch, request: request)
      case let .refused(response): response
      }
    }
    addToolRosterRoutes(&router)
    router.get("/v1/observe") { request, _ in
      let principal: Principal
      switch try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock) {
      case let .principal(resolved): principal = resolved
      case let .refused(response): return response
      }
      return try await observeResponse(space: space, url: request.url, principal: principal) {
        @Dependency(\.date) var date
        return try await identityVerdict(
          queryValues(of: request.url)["identity"], request: request, space: space, devPerson: devPerson, now: date.now,
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
      info["features"] = .array([.string(GroupHeader.feature), .string("observe-batch"), .string("watch-batch")])
      // Public discovery names the group asked for and checks nothing; the
      // routes that act in it do.
      info["group"] = .string(namedGroup(request).rawValue)
      if let aiDisclosure {
        info["aiDisclosure"] = aiDisclosureJSON(aiDisclosure)
      }
      let now = clock.now
      info["now"] = .number(now.timeIntervalSince1970)
      return clockReading(jsonResponse(.object(info)), now: now)
    }
    let discoveryContentHost = "https://" + (contentHost.pattern?.template ?? "{group}." + contentHost.base)
    addDiscoveryRoutes(&router, space: space, devPerson: devPerson, contentHost: discoveryContentHost)
    addIdentityRoutes(&router, space: space, identity: identityController, devPerson: devPerson)
    addIDTokenRoute(&router, space: space, tokens: execTokens ?? sessions?.tokens, identity: identityController)
    addGroupRoutes(&router, space: space, devPerson: devPerson) { request in
      try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
    }
    addMachineRoutes(
      &router, space: space, hub: hub, fingerprint: fingerprint,
    ) { request in
      try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
    }
    addAuthRoutes(&router, space: space, challenges: OneShotChallenges(prefix: "slc_"), fingerprint: fingerprint, devPerson: devPerson, keyStreams: keyStreams)
    addAccountRoutes(&router, space: space, devPerson: devPerson, keyStreams: keyStreams)
    addDeviceRoutes(&router, space: space, devPerson: devPerson)
    addUserRoutes(&router, space: space, devPerson: devPerson)
    addProviderRoutes(&router, space: space, usage: sessions?.usage)
    addTranscribeRoutes(&router, space: space, credentials: credentials)
    addCapabilityRoutes(&router, space: space, credentials: credentials)
    addSecretRoutes(&router, space: space, secrets: secrets) { request in
      try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
    }
    addConversationPageRoutes(&router, space: space) { request in
      try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
    }
    if let webPushApplicationServerKey {
      addWebPushRoutes(&router, space: space, applicationServerKey: webPushApplicationServerKey)
    }
    addPushRelayRoutes(&router, space: space, allowedHosts: pushRelayHosts(ProcessInfo.processInfo.environment))
    if let sessions {
      addSessionRoutes(&router, space: space, hub: hub, runtime: sessions, devPerson: devPerson) { request in
        try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
      }
      addSessionLineRoutes(&router, space: space, runtime: sessions) { request in
        try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
      }
      addObserverRoutes(&router, space: space, hub: sessions.owner) { request in
        try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock)
      }
    }
    if let webApp = webContent.webApp {
      router.get("/*") { request, _ in
        webAppResponse(webApp, request: request, contentHostPattern: contentHost.pattern)
      }
    }
    let routed = router.upgradingHandler
    // A session's exec token is its own credential, in dev as behind the wall:
    // the session gate takes every request carrying one and passes the rest on.
    let gated: (@escaping UpgradingHandler) -> UpgradingHandler = { walled in
      guard let sessions else { return walled }
      return sessionGate(
        space: space, hub: hub, machines: machines, owner: sessions.owner, tokens: sessions.tokens, runtime: sessions, credentials: credentials,
        identity: identityController, metrics: sessions.metrics, routed: routed, otherwise: walled,
      )
    }
    let content = contentHandler(
      space: space, contentHost: contentHost, advertisedOrigin: origin, devPerson: devPerson, publicRead: publicRead, webContent: webContent, pageFetch: pageFetch,
      hub: sessions?.owner,
    )
    let api = answersEviction(gated(walled(routed: routed, space: space, devPerson: devPerson, webContent: webContent, keyStreams: keyStreams)))
    // The sessions' tools reach main through this API, in process, as the
    // session whose token they carry.
    sessions?.connection.bind(.inProcess(api), dial: inProcessDial(api: api, hub: hub))
    // Both planes: a group host's page API writes cells too, and answers the
    // same 503 when the space is served elsewhere.
    return answersEviction(hostRouted(contentHost, api: api, content: content))
  }

  private static func walled(routed: @escaping UpgradingHandler, space: Space, devPerson: ResolvedPerson?, webContent: WebContent, keyStreams: KeyStreams) -> UpgradingHandler {
    @Dependency(\.date) var dateGen
    let selfAuthenticating: Set<String> = [
      "/v1/machine-v2/connect", "/v1/machine-v2/challenge", "/v1/machine-v2/enroll",
      "/v1/enroll/consume",
      "/v1/enroll/share-login", "/v1/enroll/share-login/challenge",
      "/v1/server",
      "/.well-known/openid-configuration", "/.well-known/jwks.json",
      "/v1/id-token",
    ]
    return { request in
      let v2Path = request.url.path.hasPrefix("/v1/machine-v2/") ? request.url.path.split(separator: "/") : []
      let v2KeySigned = request.headers[MachineV2Connect.pubkeyHeader] != nil && (
        (request.method == .get && v2Path.count == 3) || (request.method == .get && v2Path.count == 4 && v2Path[3] == "upgrade")
          || (request.method == .post && v2Path.count == 4 && v2Path[3] == "revoke")
      )
      // A live socket's first frame carries its assertion: browsers put no header on an upgrade.
      let liveUpgrade = request.method == .get && liveRoutePrefixes.contains { request.url.path.hasPrefix($0 + "/") }
      if selfAuthenticating.contains(request.url.path) || (request.method == .get && request.url.path == "/v1/groups") || v2KeySigned || liveUpgrade {
        return try await routed(request)
      }
      if webContent.webApp != nil, request.method == .get, !isAPIPath(request.url) {
        return try await routed(request)
      }
      switch try await bearerVerdict(request: request, space: space, now: dateGen.now) {
      case let .verified(credential):
        return try await keyStreams.bind(routed(request), to: credential.key, space: space)
      case let .rejected(response):
        return .response(response)
      case .missing:
        if devPerson != nil {
          switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: dateGen.now) {
          case .person: return try await routed(request)
          case let .refused(response): return .response(response)
          }
        }
        return .response(errorResponse(
          .unauthorized,
          code: "unauthorized",
          message: "this space admits enrolled devices only",
          hint: "enroll this device (wuhu login < invite-link), or run the server with --dev",
        ))
      }
    }
  }

  static func contentHandler(
    space: Space,
    contentHost: ContentHost,
    advertisedOrigin: String?,
    devPerson: ResolvedPerson?,
    publicRead: Bool,
    webContent: WebContent,
    pageFetch: PageFetchHandler? = nil,
    hub: Hub? = nil,
  ) -> @Sendable (GroupID, Request) async throws -> Response {
    @Dependency(\.date) var dateGen
    return { group, request in
      try await webResponse(
        space: space,
        group: group,
        contentHost: contentHost,
        advertisedOrigin: advertisedOrigin,
        now: dateGen.now,
        devPerson: devPerson,
        publicRead: publicRead,
        views: webContent.views,
        shell: webContent.scripts.isEmpty ? nil : webContent.scripts,
        pageFetch: pageFetch,
        hub: hub,
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
    aiDisclosureFile: URL? = nil,
    groupCertificate: URL? = nil,
    groupPrivateKey: URL? = nil,
    webAppDirectory: URL? = nil,
    webContent: WebContent = WebContent(),
    telemetryEnvironment: [String: String] = [:],
    hooks: ServeNIOHooks = ServeNIOHooks(),
  ) async throws {
    let aiDisclosure: AIDisclosure?
    if let aiDisclosureFile {
      aiDisclosure = try await loadAIDisclosure(file: aiDisclosureFile.path) { try Data(contentsOf: aiDisclosureFile) }
    } else { aiDisclosure = nil }
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
    let deployment = DeploymentRecord(origin: advertisedOrigin, tlsFingerprint: fingerprint, certificate: certificateKind)
    let configDirectory: URL?
    do { configDirectory = try UserConfig.directory(environment: ProcessInfo.processInfo.environment) }
    catch {
      logger.warning("credential and secret stores unavailable (\(error)); using environment credentials only")
      configDirectory = nil
    }
    var webContent = webContent
    if let webAppDirectory {
      let webApp = try WebApp.load(directory: webAppDirectory)
      webContent.webApp = webApp
      logger.notice("web app override: \(webAppDirectory.path) (\(webApp.files.count) files)")
    }
    let telemetry = try await ServerTelemetryRuntime(environment: telemetryEnvironment, version: version)
    let spaceHost: SpaceHost
    do {
      spaceHost = try await SpaceHost.open(
        folder: folder, deployment: deployment, configDirectory: configDirectory, allowEnvironmentCredentials: true,
        fallbackOrigin: "https://\(host):\(port)", port: port, dev: dev, publicRead: publicRead, contentHostPattern: contentHostPattern,
        aiDisclosure: aiDisclosure, version: version, webContent: webContent,
        devImport: devImport, devExport: devExport,
      )
    } catch {
      await telemetry?.shutdown()
      throw error
    }
    let directory = SingleSpaceDirectory(host: spaceHost)
    var options = ServeOptions()
    options.maximumWebSocketFrameBytes = MachineHub.maximumFrameBytes
    options.maximumBodyBytes = maximumPostBodyBytes
    // A roll cannot wait on a handler that never returns: the drain gives the
    // requests already running one second, then ends them with the streams.
    @Dependency(\.continuousClock) var drainClock
    options.gracefulDrain = .init(timeout: .seconds(1)) { try await drainClock.sleep(for: $0) }
    var hooks = hooks
    let upstreamDrain = hooks.onGracefulDrain
    hooks.onGracefulDrain = { outcome in
      upstreamDrain(outcome)
      switch outcome {
      case let .drained(after):
        logger.notice("graceful drain ended", metadata: ["duration_ms": "\(after.milliseconds)"])
      case let .cancelled(after, leaving):
        logger.warning("graceful drain wait cancelled", metadata: [
          "duration_ms": "\(after.milliseconds)",
          "remaining": "\(leaving.count)",
        ])
      case let .boundExpired(ending):
        for request in ending {
          logger.warning("graceful drain reached its bound: ending a request", metadata: [
            "method": "\(request.method)",
            "path": "\(request.path)",
            "version": "\(request.version)",
            "age_ms": "\(request.age.milliseconds)",
            "activity": "\(request.activity.rawValue)",
          ])
        }
      }
    }
    let upstreamShutdown = hooks.onShutdownProgress
    hooks.onShutdownProgress = { progress in
      upstreamShutdown(progress)
      switch progress {
      case let .step(name, after):
        logger.notice("serve shutdown step=\(name) duration_ms=\(after.milliseconds)")
      case let .stillClosing(after, connections):
        logger.warning("serve shutdown waiting on connections=\(connections.count) duration_ms=\(after.milliseconds)")
        for connection in connections {
          logger.warning("serve shutdown waiting on kind=\(connection.kind.rawValue) method=\(connection.method ?? "-") path=\(connection.path ?? "-") age_ms=\(connection.age.map { "\($0.milliseconds)" } ?? "-") channel_closed=\(connection.channelClosed) task_completed=\(connection.taskCompleted)")
        }
      }
    }
    let api: ServeNIOServer
    do {
      api = try await ServeNIOServer.bind(host: host, port: port, tls: identity, subdomains: groupHosts(advertisedOrigin), options: options, hooks: hooks, upgrading: directory.handler)
    } catch {
      try? await spaceHost.shutdown()
      await telemetry?.shutdown()
      throw error
    }
    // The host keeps running, unparented by this cancelled task, until the API
    // has drained: a handler waiting in a wuwei call answers before the worker
    // quiesces, which is the order a roll needs.
    let hosting = Task { await spaceHost.run() }
    await api.runUntilCancelled()
    try? await spaceHost.shutdown()
    await hosting.value
    await api.shutdown()
    if let telemetry { await telemetry.shutdown() }
    try await spaceHost.shutdown()
  }
}

/// One answer for every route whose wuwei call is refused: the space is held by
/// another serving process, or this one is draining, and a retry reaches
/// whichever process holds it next. A layer that may only throw its own error
/// carries the refusal as `EvictedRefusal` or `ToolRunError.evicted`; both come
/// back here.
func answersEviction(_ handler: @escaping UpgradingHandler) -> UpgradingHandler {
  { request in
    do {
      return try await handler(request)
    } catch {
      guard isEviction(error) else { throw error }
      return .response(evictionResponse())
    }
  }
}

/// An `Evicted` a layer could only throw as its own error crosses back to the
/// one mapping as this.
struct EvictedRefusal: Error {}

func isEviction(_ error: any Error) -> Bool {
  if error is Evicted || error is EvictedRefusal { return true }
  guard let toolError = error as? ToolRunError, case .evicted = toolError else { return false }
  return true
}

func evictionResponse() -> Response {
  var response = errorResponse(
    .serviceUnavailable,
    code: ErrorCode.unavailable.rawValue,
    message: "the space is not served by this process right now; retry",
  )
  response.headers[.retryAfter] = "1"
  return response
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
func attemptLogConfig() -> AttemptLogConfig? {
  guard let directory = ProcessInfo.processInfo.environment["WUHU_ATTEMPT_LOG_DIR"], !directory.isEmpty else {
    return nil
  }
  return AttemptLogConfig(directory: URL(fileURLWithPath: directory, isDirectory: true))
}

func toolFailure(_ error: MachineHubError, machine: MachineID) -> ToolRunError {
  switch error {
  case .machineUnattached, .execNotFound:
    .failed(code: .unavailable, message: "machine not attached: \(machine.rawValue)", hint: nil)
  }
}

/// A worker's WebSocket dial into main's API in process: the exec caller leg
/// an exec tool call follows, served in the hub's caller scope.
func inProcessDial(api: @escaping UpgradingHandler, hub: MachineHub) -> @Sendable (URL, [(String, String)]) async throws -> any FrameTransport {
  { url, headers in
    var request = Request(url: url)
    for (name, value) in headers { request.headers[name] = value }
    request.headers["connection"] = "Upgrade"
    request.headers["upgrade"] = "websocket"
    request.headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ=="
    request.headers["sec-websocket-version"] = "13"
    switch try await api(request) {
    case let .webSocket(serve):
      let (server, client) = WebSocket.pair()
      try hub.callerScope.run("worker-exec-caller") { await serve(server) }
      return WebSocketTransport(client)
    case let .response(response):
      let body = try await response.data()
      throw SpaceClient.DialRefusal(status: response.status.code, body: Array(body))
    case .boundedWebSocket:
      throw SpaceClient.DialRefusal(status: 422, body: Array(#"{"code":"unsupported","message":"exec requires a frame WebSocket transport"}"#.utf8))
    }
  }
}

extension Duration {
  fileprivate var milliseconds: Int64 {
    let parts = self.components
    return parts.seconds * 1000 + Int64(parts.attoseconds / 1_000_000_000_000_000)
  }
}
