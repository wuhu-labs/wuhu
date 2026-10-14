import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
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
import struct ExecutionOwner.AttemptLogConfig
import Fetch
import struct InferenceKit.ModelsDocument
import JSONValue
import Logging
import MachineContract
import NIOCore
import OrderedCollections
import Serve
import ServeNIO
import ServeRouting
import ServeTLS
import struct SpaceContract.AIDisclosure
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupID
import SpaceCore
import SpaceTools
import WebPush
import struct WuhuVFS.DiskVFSNode
import struct WuhuVFS.NodeTreeVFS

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
      aiDisclosure: aiDisclosure,
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
  static func configuredHandler(
    space: Space,
    hub: MachineHub,
    sessions: SessionRuntime? = nil,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    aiDisclosure: AIDisclosure? = nil,
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
    identityJWKS: JSONValue? = nil,
    identityController: IdentityController? = nil,
    machineV2Hub: MachineV2Hub? = nil,
    pageFetch: (@Sendable (Request, Set<String>, String, String, String, String, NIODeadline) async throws -> Response)? = nil,
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
    for path in ["/.well-known/openid-configuration", "/.well-known/jwks.json"] {
      router.get(path) { _, _ in
        let keys = await identityController?.jwks ?? identityJWKS
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
      info["features"] = .array([.string(GroupHeader.feature), .string("observe-batch"), .string("watch-batch")])
      // Public discovery names the group asked for and checks nothing; the
      // routes that act in it do.
      info["group"] = .string(namedGroup(request).rawValue)
      if let aiDisclosure {
        info["aiDisclosure"] = aiDisclosureJSON(aiDisclosure)
      }
      return jsonResponse(.object(info))
    }
    let discoveryContentHost = "https://" + (contentHost.pattern?.template ?? "{group}." + contentHost.base)
    sessions?.scripts.configureDiscovery(contentHost: discoveryContentHost)
    if let identityController {
      sessions?.scripts.configureDiscovery(identity: { try await identityController.snapshot() })
    }
    addDiscoveryRoutes(&router, space: space, contentHost: discoveryContentHost)
    addIdentityRoutes(&router, space: space, identity: identityController, dev: dev)
    addGroupRoutes(&router, space: space, dev: dev)
    addMachineRoutes(
      &router, space: space, hub: hub, machineV2Hub: machineV2Hub, challenges: OneShotChallenges(prefix: "mch_"), fingerprint: fingerprint,
    ) { request in
      try await requestPrincipal(request, space: space, date: clock)
    }
    if let machineV2Hub {
      addMachineV2Routes(&router, space: space, hub: machineV2Hub, fingerprint: fingerprint) { request in
        try await requestPrincipal(request, space: space, date: clock)
      }
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
    }
    if let webApp {
      router.get("/*") { request, _ in
        webAppResponse(webApp, request: request, contentHostPattern: contentHost.pattern)
      }
    }
    let routes = router.upgradingHandler
    let routed: UpgradingHandler = { request in
      if let machineV2Hub, request.url.path == "/v1/machine-v2" || request.url.path.hasPrefix("/v1/machine-v2/") {
        do { try await machineV2Hub.checkAvailable() }
        catch let error as OperationError { return .response(try Response.json(ErrorEnvelope(error), status: .serviceUnavailable)) }
      }
      return try await routes(request)
    }
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
      space: space, contentHost: contentHost, advertisedOrigin: origin, dev: dev, publicRead: publicRead, views: views, pageFetch: pageFetch,
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
      "/v1/machine-v2/connect", "/v1/machine-v2/challenge", "/v1/machine-v2/enroll",
      "/v1/enroll/consume",
      "/v1/enroll/share-login", "/v1/enroll/share-login/challenge",
      "/v1/server", "/v1/groups",
      "/.well-known/openid-configuration", "/.well-known/jwks.json",
    ]
    return hostRouted(contentHost, api: gated { request in
      let v2KeyStatus = request.method == .get && request.headers[MachineV2Connect.pubkeyHeader] != nil && request.url.path.hasPrefix("/v1/machine-v2/") && request.url.path.split(separator: "/").count == 3
      if selfAuthenticating.contains(request.url.path) || v2KeyStatus {
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
    pageFetch: PageFetchHandler? = nil,
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
        pageFetch: pageFetch,
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
    hooks: ServeNIOHooks = ServeNIOHooks(),
  ) async throws {
    let aiDisclosure: AIDisclosure?
    if let aiDisclosureFile {
      aiDisclosure = try await loadAIDisclosure(
        from: NodeTreeVFS(root: DiskVFSNode(path: aiDisclosureFile.deletingLastPathComponent().path, isMutable: false)),
        path: "/" + aiDisclosureFile.lastPathComponent, file: aiDisclosureFile.path,
      )
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
    let webApp: WebApp?
    if let webAppDirectory {
      webApp = try WebApp.load(directory: webAppDirectory)
      logger.notice("web app override: \(webAppDirectory.path) (\(webApp!.files.count) files)")
    } else { webApp = .embedded }
    let spaceHost = try await SpaceHost.open(
      folder: folder, deployment: deployment, configDirectory: configDirectory,
      fallbackOrigin: "https://\(host):\(port)", port: port, dev: dev, publicRead: publicRead, contentHostPattern: contentHostPattern,
      aiDisclosure: aiDisclosure, version: version, webApp: webApp,
      devImport: devImport, devExport: devExport,
    )
    let directory = SingleSpaceDirectory(host: spaceHost)
    var options = ServeOptions()
    options.maximumWebSocketFrameBytes = MachineHub.maximumFrameBytes
    options.maximumBodyBytes = maximumPostBodyBytes
    let api: ServeNIOServer
    do {
      api = try await ServeNIOServer.bind(
        host: host, port: port, tls: identity, subdomains: groupHosts(advertisedOrigin), options: options, hooks: hooks,
        upgrading: directory.handler,
      )
    } catch { try? await spaceHost.shutdown(); throw error }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await spaceHost.run() }
      await api.runUntilCancelled()
      try? await spaceHost.shutdown()
      group.cancelAll()
    }
    try await spaceHost.shutdown()
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
  case .frameTooLarge:
    .failed(code: .invalidArgument, message: "request for machine \(machine.rawValue) exceeds the 16 MiB frame ceiling", hint: nil)
  case .machineLost:
    .failed(code: .unavailable, message: "machine \(machine.rawValue) stopped responding", hint: nil)
  case .machineUnattached, .execNotFound, .severed:
    .failed(code: .unavailable, message: "machine not attached: \(machine.rawValue)", hint: nil)
  }
}
