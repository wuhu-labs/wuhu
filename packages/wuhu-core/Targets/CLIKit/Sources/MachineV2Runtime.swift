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
import class AsyncHTTPClient.HTTPClient
import Crypto
import enum ExecSupervisor.ExecSupervisor
import Fetch
import FetchAsyncHTTPClient
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
import struct NIOCore.IOError
import class NIOPosix.MultiThreadedEventLoopGroup
import struct OperationProtocol.ErrorEnvelope
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
  ) async throws -> Bool {
    guard arguments.first == "machine-v2" else { return false }
    if arguments.count == 1 || arguments == ["machine-v2", "--help"] || (arguments.count >= 2 && ["run", "leave", "preflight", "join"].contains(arguments[1]) && arguments.contains("--help")) {
      await stdout("""
      usage: wuhu machine-v2 join <https-origin> [fingerprint] [--name <name-v2>] < v2-token
             wuhu machine-v2 install|upgrade <id> --binary <signed-wuhu>
             wuhu machine-v2 rollback|uninstall <id>
             wuhu machine-v2 run|leave <id>
             wuhu machine-v2 preflight <id> <private-result-path>

      """)
      return true
    }
    guard arguments.count >= 2, ["run", "leave", "preflight", "join"].contains(arguments[1]) else { return false }
    guard case .wallet = try Identity.resolve(environment: environment) else { throw CLIError(message: sessionRefusal) }
    let trust = try ServerTrust(environment: environment)
    switch arguments[1] {
    case "join":
      guard (3 ... 6).contains(arguments.count) else { throw UsageError(message: "machine-v2 join <https-origin> [fingerprint] [--name <name-v2>] < v2-token") }
      var fingerprint: String?; var name: String?
      var i = 3
      while i < arguments.count {
        if arguments[i] == "--name", i + 1 < arguments.count, name == nil { name = arguments[i + 1]; i += 2 }
        else if fingerprint == nil, ServerTrust.isFingerprint(arguments[i]) { fingerprint = arguments[i]; i += 1 }
        else { throw UsageError(message: "invalid machine-v2 join option") }
      }
      let machine = try await join(server: arguments[2], fingerprint: fingerprint, name: name, token: stdin(), environment: environment, trust: trust, fetch: fetch)
      await stdout("joined \(machine)\n")
    case "run":
      guard arguments.count == 3 else { throw UsageError(message: "machine-v2 run <id>") }
      try await run(home: .locate(environment: environment, machine: arguments[2]), trust: trust, fetch: fetch, recording: environment["WUHU_MACHINE_V2_RECORDING"].map { URL(fileURLWithPath: $0) })
    case "leave":
      guard arguments.count == 3 else { throw UsageError(message: "machine-v2 leave <id>") }
      try await leave(home: .locate(environment: environment, machine: arguments[2]))
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
      named = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    guard !named.isEmpty else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Machine name must not be empty") }
    let namedV2 = named.hasSuffix("-v2") ? named : named + "-v2"
    guard fingerprint.map(ServerTrust.isFingerprint) ?? true else { throw MachineV2RuntimeError(.invalidConfiguration) }
    let pin = try fingerprint ?? ServerTrust.hostKey(url: origin).flatMap { try trust.pin(forHost: $0) }
    let fetch = pinnedFetch(pin, plain: fetch)
    let key = Curve25519.Signing.PrivateKey()
    let request = Request(url: URL(string: server + "/v1/machine-v2/enroll")!, method: .post, body: try .json(["token": token, "pubkey": key.pubkeyLabel, "name": namedV2]))
    let response = try await fetch(request)
    guard response.status.code == 200 else { throw MachineV2RuntimeError(.enrollmentFailed, message: "Enrollment HTTP \(response.status.code)") }
    let enrolled = try await response.body.json(EnrollConsumeOutput.self, upTo: 8192)
    guard let machine = enrolled.machine, let enrolledName = enrolled.machineName, enrolledName.hasSuffix("-v2") else { throw MachineV2RuntimeError(.machineNotV2) }
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
    let headers = try await authentication(server: config.server, machine: config.machine, key: key, fetch: pinnedFetch(config.fingerprint, plain: fetch))
    do { return try await TunnelWebSocket.connect(WebSocketRequest(url: url, headers: headers, tls: tls, connectTimeout: .seconds(5)), connector: connector) }
    catch let WebSocketError.refused(status, _, _) {
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

  static func run(home: MachineV2Home, trust: ServerTrust, fetch: FetchClient, recording: URL? = nil) async throws {
    _ = try home.load(); _ = try home.loadKey(); try home.prepare()
    guard FileManager.default.isExecutableFile(atPath: home.binary.path) else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Install this machine's own v2 binary first") }
    let recorder = try recording.map { try MachineV2Recording(root: $0) }
    try await ExecSupervisor.runComputerAgent(machine: home.machine, operationsDirectory: home.operationsDirectory.path, controlSocket: home.socket.path, executable: home.binary.path) { handler, acknowledged in
      let handler = recorder?.handler(handler) ?? handler
      try await dialLoop(handler: handler, leaveAcknowledged: acknowledged, connect: { try await connect(home: home, trust: trust, fetch: fetch) })
    }
  }

  static func dialLoop(handler: @escaping Handler, leaveAcknowledged: @escaping @Sendable () async -> Bool, connect: @escaping @Sendable () async throws -> TunnelTransport, clock: OperationClock = .continuous) async throws {
    while !Task.isCancelled {
      if await leaveAcknowledged() {
        try await clock.sleep(.seconds(2))
        continue
      }
      do {
        let transport = try await connect()
        defer { transport.abort() }
        try await ServeTunnel.run(handler: handler, over: transport)
      } catch is CancellationError { throw CancellationError() }
      catch let error as MachineV2RuntimeError { if error.code != .serverUnavailable { throw error } }
      catch { try Task.checkCancellation() }
      try await clock.sleep(.seconds(2))
    }
  }

  static func leave(home: MachineV2Home) async throws {
    try home.validate()
    var state = stat()
    guard lstat(home.socket.path, &state) == 0, state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK, state.st_mode & 0o777 == 0o600,
          let encoded = home.socket.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics), let url = URL(string: "http+unix://" + encoded + "/leave") else { throw MachineV2RuntimeError(.drainFailed, message: "No owner-private v2 control socket") }
    var configuration = HTTPClient.Configuration(); configuration.redirectConfiguration = .disallow
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let http = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
    let result: Result<Void, any Error>
    do {
      var request = Request(url: url, method: .put)
      request.headers["Host"] = "localhost"
      let response = try await FetchClient.asyncHTTPClient(http, timeout: .seconds(65))(request)
      try await validateLeaveResponse(response)
      result = .success(())
    } catch { result = .failure(error) }
    var teardownFailure: (any Error)?
    do { try await http.shutdown() } catch { teardownFailure = error }
    do { try await group.shutdownGracefully() } catch { teardownFailure = teardownFailure ?? error }
    try result.get()
    if let teardownFailure { throw teardownFailure }
  }

  static func validateLeaveResponse(_ response: Response) async throws {
    if response.status.code != 200 {
      let failure: ErrorEnvelope
      do { failure = try await response.body.json(ErrorEnvelope.self, upTo: 8192) }
      catch { throw MachineV2RuntimeError(.drainFailed, message: "Malformed local leave error receipt") }
      throw MachineV2RuntimeError(failure.error.code == .requestDeadline && failure.error.message == "leaveUnacknowledged" ? .leaveUnacknowledged : .drainFailed, message: failure.error.message)
    }
    let left: Bool
    do { left = try await response.body.json(Bool.self, upTo: 32) }
    catch { throw MachineV2RuntimeError(.drainFailed, message: "Malformed local leave receipt") }
    guard left else { throw MachineV2RuntimeError(.drainFailed, message: "Negative local leave receipt") }
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
