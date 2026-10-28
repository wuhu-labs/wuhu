import DeploymentAdmin
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Assertion
import Crypto
import Dependencies
import enum ExecSupervisor.ExecSupervisor
import Fetch
import struct FetchTunnel.TunnelLimits
import struct FetchTunnel.TunnelTransport
import enum FetchTunnelWebSocket.TunnelWebSocket
import enum FetchWebSocket.ClientTLS
import struct FetchWebSocket.WebSocketConnector
import enum FetchWebSocket.WebSocketError
import struct FetchWebSocket.WebSocketRequest
import enum JSONValue.JSONValue
import struct MachineContract.MachineChallengeOutput
import struct MachineContract.MachineStatus
import enum MachineContract.MachineV2Connect
import struct MachineContract.MachineV2Upgrade
import struct NIOCore.IOError
import struct OperationProtocol.OperationClock
import enum PinnedTLS.PinnedTLS
import typealias Serve.Handler
import enum ServeTunnel.ServeTunnel
import struct SpaceContract.EnrollConsumeOutput

public enum MachineV2Runtime {
  public static func command(
    arguments: [String],
    environment: [String: String],
    fetch: FetchClient,
    stdin: @Sendable () async throws -> String,
    stdout: @Sendable (String) async -> Void,
    version: String = "0.0.0-unstamped",
    serviceCommand: (@Sendable ([String]) async throws -> String)? = nil,
  ) async throws -> Bool {
    guard arguments.first == "machine-v2" else { return false }
    if arguments.count == 1 || arguments == ["machine-v2", "--help"] || (arguments.count >= 2 && ["run", "preflight", "join"].contains(arguments[1]) && arguments.contains("--help")) {
      await stdout("""
      usage: wuhu machine-v2 add --name <name>
             wuhu machine-v2 join <https-origin> [fingerprint] [--name <name>] < v2-token
             wuhu machine-v2 install|upgrade <id> --binary <signed-wuhu>
             wuhu machine-v2 rollback|uninstall <id>
             wuhu machine-v2 run <id>
             wuhu machine-v2 preflight <id> <private-result-path>

      """)
      return true
    }
    guard arguments.count >= 2, ["run", "preflight", "join", "apply-upgrade"].contains(arguments[1]) else { return false }
    guard case .wallet = try Identity.resolve(environment: environment) else { throw CLIError(message: machineV2SessionRefusal(arguments[1])) }
    let trust = try ServerTrust(environment: environment)
    switch arguments[1] {
    case "join":
      guard (3 ... 6).contains(arguments.count) else { throw UsageError(message: "machine-v2 join <https-origin> [fingerprint] [--name <name>] < v2-token") }
      var fingerprint: String?; var name: String?
      var i = 3
      while i < arguments.count {
        if arguments[i] == "--name", i + 1 < arguments.count, name == nil { name = arguments[i + 1]; i += 2 }
        else if fingerprint == nil, ServerTrust.isFingerprint(arguments[i]) { fingerprint = arguments[i]; i += 1 }
        else { throw UsageError(message: "invalid machine-v2 join option") }
      }
      let machine = try await join(server: arguments[2], fingerprint: fingerprint, name: name, token: stdin(), environment: environment, trust: trust, fetch: fetch)
      await stdout("joined \(machine)\ninstall service: wuhu machine-v2 install \(machine) --binary <signed-wuhu>\nor run in foreground: wuhu machine-v2 run \(machine)\n")
    case "run":
      try DeploymentAdminPolicy.requireMachineAgentUser()
      guard arguments.count == 3 else { throw UsageError(message: "machine-v2 run <id>") }
      let home = try MachineV2Home.locate(environment: environment, machine: arguments[2])
      let installed = serviceCommand.flatMap { command in CommandLine.arguments.first == home.binary.path ? command : nil }
      let upgrader = installed.flatMap { liveUpgrader(home: home, version: version, fetch: fetch, command: $0) }
      let service = installed.flatMap { command in
        environment["HOME"].flatMap { MachineV2Service(MachineV2Installer.local(home: URL(fileURLWithPath: $0), machine: home.machine, environment: environment, command: command), environment: environment, controlGroups: try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)) }
      }
      try await run(home: home, trust: trust, fetch: fetch, recording: environment["WUHU_MACHINE_V2_RECORDING"].map { URL(fileURLWithPath: $0) }, upgrader: upgrader, service: service)
    case "apply-upgrade":
      guard arguments.count == 6, let serviceCommand, let path = environment["HOME"] else { throw UsageError(message: "machine-v2 apply-upgrade <id> <candidate> <version> <token>") }
      let home = try MachineV2Home.locate(environment: environment, machine: arguments[2])
      try home.validate()
      let installer = MachineV2Installer.local(home: URL(fileURLWithPath: path), machine: home.machine, environment: environment, command: serviceCommand)
      await MachineV2AutoUpgrade.apply(home: home, candidate: URL(fileURLWithPath: arguments[3]), target: arguments[4], running: version, token: arguments[5], installer: installer)
    default:
      guard arguments.count == 4 else { throw UsageError(message: "machine-v2 preflight <id> <result-path>") }
      try await preflight(home: .locate(environment: environment, machine: arguments[2]), trust: trust, fetch: fetch, result: URL(fileURLWithPath: arguments[3]))
    }
    return true
  }

  static func join(server: String, fingerprint: String?, name: String?, token: String, environment: [String: String], trust: ServerTrust, fetch: FetchClient) async throws -> String {
    guard let origin = URL(string: server), origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Join requires an HTTPS origin") }
    let server = server.hasSuffix("/") ? String(server.dropLast()) : server
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw MachineV2RuntimeError(.enrollmentFailed, message: "Expected explicit v2 token on stdin") }
    var hostname = [CChar](repeating: 0, count: 256)
    let named: String
    if let name { named = name }
    else {
      guard gethostname(&hostname, hostname.count - 1) == 0 else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Cannot read hostname; provide --name") }
      named = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).replacingOccurrences(of: "-", with: "_")
    }
    guard !named.isEmpty else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Machine name must not be empty") }
    guard fingerprint.map(ServerTrust.isFingerprint) ?? true else { throw MachineV2RuntimeError(.invalidConfiguration) }
    let pin = try fingerprint ?? ServerTrust.hostKey(url: origin).flatMap { try trust.pin(forHost: $0) }
    let fetch = pinnedFetch(pin, plain: fetch)
    let key = Curve25519.Signing.PrivateKey()
    let request = Request(url: URL(string: server + "/v1/machine-v2/enroll")!, method: .post, body: try .json(["token": token, "pubkey": key.pubkeyLabel, "name": named]))
    let response = try await fetch(request)
    guard response.status.code == 200 else { throw MachineV2RuntimeError(.enrollmentFailed, message: "Enrollment HTTP \(response.status.code)") }
    let enrolled = try await response.body.json(EnrollConsumeOutput.self, upTo: 8192)
    guard let machine = enrolled.machine, let enrolledName = enrolled.machineName else { throw MachineV2RuntimeError(.machineNotV2) }
    var verify = Request(url: URL(string: server + "/v1/machine-v2/" + machine)!)
    verify.headers = try await authentication(server: server, machine: machine, key: key, fetch: fetch)
    let verification = try await fetch(verify)
    guard verification.status.code == 200 else { throw MachineV2RuntimeError(.machineNotV2, message: "Token does not enroll explicit v2 membership") }
    let status = try await verification.body.json(MachineStatus.self, upTo: 8192)
    guard status.id.rawValue == machine, status.name == enrolledName else { throw MachineV2RuntimeError(.machineNotV2) }
    let home = try MachineV2Home.locate(environment: environment, machine: machine)
    try home.save(.init(machine: machine, name: enrolledName, server: server, fingerprint: pin), key: key)
    return machine
  }

  static func connect(home: MachineV2Home, trust: ServerTrust, fetch: FetchClient, connector: WebSocketConnector = .live) async throws -> TunnelTransport {
    let config = try home.load(); let key = try home.loadKey()
    let url = URL(string: config.server + "/v1/machine-v2/connect")!
    let tls: ClientTLS? = config.fingerprint.map { .pinned(fingerprint: $0) }
    var headers = try await authentication(server: config.server, machine: config.machine, key: key, fetch: pinnedFetch(config.fingerprint, plain: fetch))
    headers[MachineV2Connect.tunnelStreamsHeader] = String(MachineV2Connect.tunnelStreams)
    do { return try await TunnelWebSocket.connect(WebSocketRequest(url: url, headers: headers, tls: tls, connectTimeout: .seconds(5)), connector: connector) }
    catch let WebSocketError.refused(status, _, body) {
      // Only the server's definitive 401 says the key is dead (revoked, or a machine it no longer knows); a rejected handshake may be a stale challenge.
      if status == 401, JSONValue.parse(String(decoding: body, as: UTF8.self))?.object?["code"]?.stringValue == "machineNotAuthorized" {
        throw MachineV2RuntimeError(.revoked, message: "The server revoked this machine or no longer knows it")
      }
      throw MachineV2RuntimeError(status >= 500 ? .serverUnavailable : .enrollmentFailed, message: "Tunnel HTTP \(status)")
    } catch let WebSocketError.invalidConfiguration(message) { throw MachineV2RuntimeError(.invalidConfiguration, message: message) }
    catch let WebSocketError.invalidURL(message) { throw MachineV2RuntimeError(.invalidConfiguration, message: message) }
    catch let WebSocketError.tls(message) { throw MachineV2RuntimeError(.invalidConfiguration, message: message) }
  }

  static func pinnedFetch(_ fingerprint: String?, plain: FetchClient) -> FetchClient {
    guard let fingerprint else { return plain }
    return FetchClient { request in try await PinnedTLS.fetch(request, pinnedFingerprint: fingerprint, timeout: .seconds(5)) }
  }

  static func authentication(server: String, machine: String, key: Curve25519.Signing.PrivateKey, fetch: FetchClient) async throws -> RequestHeaders {
    let response = try await fetch(Request(url: URL(string: server + "/v1/machine-v2/challenge")!))
    guard response.status.code == 200 else { throw MachineV2RuntimeError(response.status.code >= 500 ? .serverUnavailable : .enrollmentFailed, message: "Challenge HTTP \(response.status.code)") }
    let challenge = try await response.body.json(MachineChallengeOutput.self, upTo: 8192)
    let machines = [machine]
    let signature = try key.signature(for: MachineV2Connect.signingPayload(challenge: challenge.challenge, machines: machines))
    var headers = RequestHeaders()
    headers[MachineV2Connect.pubkeyHeader] = key.pubkeyLabel
    headers[MachineV2Connect.challengeHeader] = challenge.challenge
    headers[MachineV2Connect.signatureHeader] = signature.base64EncodedString()
    headers[MachineV2Connect.machinesHeader] = machine
    return headers
  }

  static func liveUpgrader(home: MachineV2Home, version: String, fetch: FetchClient, command: @escaping @Sendable ([String]) async throws -> String) -> MachineV2AutoUpgrader? {
    guard let config = try? home.load(), let key = try? home.loadKey() else { return nil }
    @Dependency(UpgradeEnvironment.self) var upgrade
    let server = pinnedFetch(config.fingerprint, plain: fetch)
    let origin = URL(string: config.server)
    return MachineV2AutoUpgrader(home: home, version: version, platform: ReleasePlatform.current?.name, environment: .init(
      announce: {
        var request = Request(url: URL(string: config.server + "/v1/machine-v2/" + config.machine + "/upgrade")!)
        request.headers = try await authentication(server: config.server, machine: config.machine, key: key, fetch: server)
        let response = try await server(request)
        guard response.status.code == 200 else { throw MachineV2RuntimeError(.serverUnavailable, message: "Upgrade announcement HTTP \(response.status.code)") }
        return try await response.body.json(MachineV2Upgrade.self, upTo: 65536)
      },
      download: { url in
        if let fingerprint = config.fingerprint, url.host == origin?.host, url.port == origin?.port {
          let response = try await PinnedTLS.fetch(Request(url: url), pinnedFingerprint: fingerprint, timeout: .minutes(10))
          return try await response.validateStatus().data(upTo: 1 << 30)
        }
        return try await ReleaseChannel(fetch: upgrade.fetch).download(url, upTo: 1 << 30)
      },
      extract: upgrade.extract,
      command: command,
      verifySignature: { try MachineV2AutoUpgrade.verifySignature($0, running: $1) },
      launch: { try ExecSupervisor.launchDetached($0) },
      reaped: { ExecSupervisor.reapIfExited($0) },
    ))
  }

  static func run(home: MachineV2Home, trust: ServerTrust, fetch: FetchClient, recording: URL? = nil, upgrader: MachineV2AutoUpgrader? = nil, service: MachineV2Service? = nil, clock: OperationClock = .continuous) async throws {
    try DeploymentAdminPolicy.requireMachineAgentUser()
    _ = try home.load(); _ = try home.loadKey(); try home.prepare()
    guard FileManager.default.isExecutableFile(atPath: home.binary.path) else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Install this machine's own v2 binary first") }
    let recorder = try recording.map { try MachineV2Recording(root: $0) }
    @Sendable func serve(_ handler: @escaping Handler) async throws {
      let handler = MachineV2AutoUpgrade.reporting(recorder?.handler(handler) ?? handler, home: home)
      guard let upgrader else {
        return try await dialLoop(handler: handler, connect: { try await connect(home: home, trust: trust, fetch: fetch) })
      }
      let (checks, check) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await dialLoop(handler: handler, connect: { try await connect(home: home, trust: trust, fetch: fetch) }, connected: {
            await upgrader.connected()
            check.yield()
          })
        }
        group.addTask {
          while true {
            try await clock.sleep(MachineV2AutoUpgrade.checkInterval)
            check.yield()
          }
        }
        group.addTask { for await _ in checks { await upgrader.check() } }
        defer { group.cancelAll() }
        try await group.next()
      }
    }
    try await ExecSupervisor.runComputerAgent(machine: home.machine, operationsDirectory: home.operationsDirectory.path, executable: home.binary.path) { handler, retire in
      try await retiringOnRevoke(home: home, service: service, clock: clock, retire: { await retire(.revoked) }) { try await serve(handler) }
    }
  }

  /// Runs `serve`; when the server revokes the machine, retires every supervisor and rethrows.
  /// Inside its installed job it first stops the job, whatever the loaded definition says about a clean exit, and parks
  /// if it cannot. The home stays: it holds the key, configuration and executable the uninstall still uses.
  static func retiringOnRevoke(home: MachineV2Home, service: MachineV2Service? = nil, clock: OperationClock = .continuous, retire: () async -> Void, _ serve: () async throws -> Void) async throws {
    do { try await serve() }
    catch let error as MachineV2RuntimeError where error.code == .revoked {
      await retire()
      if let service, await !stops(service, home: home) { try await park(home: home, clock: clock) }
      throw error
    }
  }

  /// Whether the service manager has stopped the job for good.
  static func stops(_ service: MachineV2Service, home: MachineV2Home) async -> Bool {
    home.logUpgrade("revoked; stopping the service job")
    do { try await service.stop(); return true }
    catch { home.logUpgrade("cannot stop the service job: \(error)"); return false }
  }

  /// A revoked agent that cannot stop its job stays alive and idle: no network, no reconnect, no exec. A signal
  /// (uninstall stops the job) ends it.
  static func park(home: MachineV2Home, clock: OperationClock) async throws {
    home.logUpgrade("revoked; parked: the service manager would restart an exit")
    while true { try await clock.sleep(.seconds(3600)) }
  }

  /// How `wuhu` exits after `machine-v2` fails. A revoked machine is the one clean end of `run`: it exits 0, which the
  /// installed service treats as final (systemd `RestartPreventExitStatus=0`, launchd `KeepAlive.SuccessfulExit = false`);
  /// every other failure exits 1 and the service manager restarts it.
  public static func exitStatus(for error: any Error) -> Int32 {
    (error as? MachineV2RuntimeError)?.code == .revoked ? 0 : 1
  }

  static func dialLoop(handler: @escaping Handler, connect: @escaping @Sendable () async throws -> TunnelTransport, connected: @escaping @Sendable () async -> Void = {}, clock: OperationClock = .continuous) async throws {
    while !Task.isCancelled {
      do {
        let transport = try await connect()
        defer { transport.abort() }
        await connected()
        try await ServeTunnel.run(handler: handler, over: transport, limits: TunnelLimits(streams: MachineV2Connect.tunnelStreams))
      } catch is CancellationError { throw CancellationError() }
      catch let error as MachineV2RuntimeError { if error.code != .serverUnavailable { throw error } }
      catch { try Task.checkCancellation() }
      try await clock.sleep(.seconds(2))
    }
  }

  static func revoke(home: MachineV2Home, fetch: FetchClient) async throws {
    let config = try home.load()
    let key = try home.loadKey()
    let fetch = pinnedFetch(config.fingerprint, plain: fetch)
    do {
      var request = Request(url: URL(string: config.server + "/v1/machine-v2/" + config.machine + "/revoke")!, method: .post)
      request.headers = try await authentication(server: config.server, machine: config.machine, key: key, fetch: fetch)
      let response = try await fetch(request)
      if response.status.code == 401,
         try await response.body.json(JSONValue.self, upTo: 8192).object?["code"]?.stringValue == "machineNotAuthorized" { return }
      guard response.status.code == 200 else {
        throw MachineV2RuntimeError(response.status.code >= 500 ? .serverUnavailable : .enrollmentFailed, message: "Self-revoke HTTP \(response.status.code)")
      }
    } catch let error as MachineV2RuntimeError { throw error }
    catch { throw MachineV2RuntimeError(.serverUnavailable, message: "Cannot revoke the machine: \(error)") }
  }

  static func preflight(home: MachineV2Home, trust: ServerTrust, fetch: FetchClient, result: URL) async throws {
    struct Receipt: Encodable { var ok: Bool; var code: String?; var message: String? }
    try home.validate()
    guard result.deletingLastPathComponent().standardizedFileURL == home.directory.standardizedFileURL, !FileManager.default.fileExists(atPath: result.path) else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Preflight receipt must be a new file in the private v2 home") }
    let receipt: Receipt
    do {
      let transport = try await connect(home: home, trust: trust, fetch: fetch)
      transport.abort()
      receipt = Receipt(ok: true)
    } catch {
      let denied = (error as? IOError).map { $0.errnoCode == EACCES || $0.errnoCode == EPERM } ?? false
      let code = denied ? MachineV2RuntimeError.Code.localNetworkDenied : ((error as? MachineV2RuntimeError)?.code ?? .preflightFailed)
      receipt = Receipt(ok: false, code: code.rawValue, message: String(describing: error))
    }
    try JSONEncoder().encode(receipt).write(to: result, options: .withoutOverwriting)
    guard chmod(result.path, 0o600) == 0 else { throw MachineV2RuntimeError(.invalidConfiguration) }
  }
}

/// The installed job an agent runs as.
struct MachineV2Service: Sendable {
  /// Returns once the service manager will not start the job again.
  var stop: @Sendable () async throws -> Void

  init(stop: @escaping @Sendable () async throws -> Void) { self.stop = stop }

  /// Nil outside the installed job (a foreground `run`). `controlGroups` is `/proc/self/cgroup`.
  init?(_ installer: MachineV2Installer, environment: [String: String], controlGroups: String?) {
    let inJob = switch installer.platform {
    // launchd names each job's process by its label.
    case .macOS: environment["XPC_SERVICE_NAME"] == installer.label
    case .linux: controlGroups?.split(separator: "\n").contains { $0.hasSuffix("/" + installer.unit) } ?? false
    }
    guard inJob else { return nil }
    self.stop = { try await installer.stopRunningJob() }
  }
}
