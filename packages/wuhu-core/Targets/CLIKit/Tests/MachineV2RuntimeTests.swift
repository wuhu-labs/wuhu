#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Assertion
@testable import CLIKit
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Crypto
import Fetch
import FetchExchangeRecording
import FetchTunnel
import FetchWebSocket
import enum JSONValue.JSONValue
import enum MachineContract.MachineV2Connect
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import Scratch
import ScratchTesting
import class ServeNIO.ServeNIOServer
import Synchronization
import Testing

private actor EnrollmentEffects {
  var requests: [Request] = []
  var pubkey: String?
  var refuseV2 = false
  init(refuseV2: Bool = false) { self.refuseV2 = refuseV2 }
  func fetch(_ request: Request) async throws -> Response {
    requests.append(request)
    switch request.url.path {
    case "/v1/machine-v2/enroll":
      let body = try await request.json(JSONValue.self)
      #expect(body.object?["name"] == "box-v2")
      #expect(body.object?["token"] == "explicit-token")
      pubkey = body.object?["pubkey"]?.stringValue
      if refuseV2 { return .text("v1-token-refused", status: .forbidden) }
      return try .json(JSONValue.object(["account": "machine-account", "capabilities": ["execMachine"], "machine": "mc_test", "machineName": "box-v2"]))
    case "/v1/machine-v2/challenge": return try .json(["challenge": "one-shot"])
    case "/v1/machine-v2/mc_test":
      #expect(request.headers[MachineV2Connect.pubkeyHeader] == pubkey)
      #expect(request.headers[MachineV2Connect.challengeHeader] == "one-shot")
      #expect(request.headers[MachineV2Connect.machinesHeader] == "mc_test")
      let key = try #require(VerifyingKey(label: pubkey!))
      let signature = try #require(Data(base64Encoded: request.headers[MachineV2Connect.signatureHeader]!))
      #expect(key.isValidSignature(signature, for: MachineV2Connect.signingPayload(challenge: "one-shot", machines: ["mc_test"])))
      return try .json(JSONValue.object(["id": "mc_test", "name": "box-v2", "attached": false]))
    default: Issue.record("unexpected path \(request.url.path)"); return .text("unexpected", status: .notFound)
    }
  }

  nonisolated var client: FetchClient { FetchClient { try await self.fetch($0) } }
}

@Suite struct MachineV2RuntimeTests {
  func fixture(_ label: String = "machine-v2-runtime") throws -> (scratch: ScratchFolder, root: URL) {
    let scratch = try ScratchFolder(label)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
    let resolved = try #require(realpath(scratch.path, nil))
    defer { free(resolved) }
    return (scratch, URL(fileURLWithPath: String(cString: resolved)))
  }

  @Test func joinUsesDedicatedEnrollmentAndAuthenticatesMembershipWithoutV1State() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let legacy = root.appendingPathComponent(".wuhu/machine")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let sentinel = legacy.appendingPathComponent("machine.key")
    try Data("legacy untouched".utf8).write(to: sentinel)
    let trust = ServerTrust(directory: root.appendingPathComponent(".wuhu"))
    let effects = EnrollmentEffects()
    let machine = try await MachineV2Runtime.join(server: "https://example.test", fingerprint: nil, name: "box", token: "explicit-token\n", environment: ["HOME": root.path], trust: trust, fetch: effects.client)
    #expect(machine == "mc_test")
    let home = try MachineV2Home.locate(environment: ["HOME": root.path], machine: machine)
    #expect(try home.load() == .init(machine: "mc_test", name: "box-v2", server: "https://example.test"))
    #expect(try home.loadKey().pubkeyLabel == (await effects.pubkey))
    #expect(try Data(contentsOf: sentinel) == Data("legacy untouched".utf8))
    #expect(await effects.requests.map(\.url.path) == ["/v1/machine-v2/enroll", "/v1/machine-v2/challenge", "/v1/machine-v2/mc_test"])
  }

  @Test func dialUsesBoundedGenericAdapterExactSubprotocolAndV2Proof() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let home = MachineV2Home(root: root, machine: "test")
    let key = Curve25519.Signing.PrivateKey()
    try home.save(.init(machine: "test", name: "box-v2", server: "https://example.test"), key: key)
    let fetch = FetchClient { request in
      #expect(request.url.path == "/v1/machine-v2/challenge")
      return try .json(["challenge": "dial-challenge"])
    }
    let connector = WebSocketConnector { request in
      #expect(request.url.absoluteString == "https://example.test/v1/machine-v2/connect")
      #expect(request.headers["Sec-WebSocket-Protocol"] == TunnelTransport.webSocketSubprotocol)
      #expect(request.headers[MachineV2Connect.pubkeyHeader] == key.pubkeyLabel)
      #expect(request.limits.messageBytes == 1024 * 1024)
      #expect(request.limits.bufferedReceiveBytes == 1024 * 1024)
      #expect(request.limits.outboundMessageBytes == 1024 * 1024)
      let signature = try #require(Data(base64Encoded: request.headers[MachineV2Connect.signatureHeader]!))
      #expect(key.publicKey.isValidSignature(signature, for: MachineV2Connect.signingPayload(challenge: "dial-challenge", machines: ["test"])))
      var headers = Headers(); headers[.init("Sec-WebSocket-Protocol")!] = TunnelTransport.webSocketSubprotocol
      return WebSocketConnection(responseHeaders: headers, inbound: WebSocketInbound(AsyncThrowingStream { $0.finish() }), send: { _ in }, close: { _ in }, abort: {})
    }
    let transport = try await MachineV2Runtime.connect(home: home, trust: .init(directory: root), fetch: fetch, connector: connector)
    #expect(transport.maxMessageBytes == 1024 * 1024)
    transport.abort()
  }

  @Test func onlyTheServersMachineNotAuthorizedRefusalReadsAsRevoked() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let home = MachineV2Home(root: root, machine: "test")
    try home.save(.init(machine: "test", name: "box-v2", server: "https://example.test"), key: Curve25519.Signing.PrivateKey())
    let fetch = FetchClient { _ in try .json(["challenge": "dial-challenge"]) }
    let cases: [(Int, String, MachineV2RuntimeError.Code)] = [
      (401, #"{"code":"machineNotAuthorized","message":"Not a live key of this Machine v2 identity"}"#, .revoked),
      (401, #"{"code":"machineNotAuthorized","message":"Not an enrolled Machine v2 identity"}"#, .revoked),
      (401, #"{"code":"keyInvalid"}"#, .enrollmentFailed),
      (401, "not json", .enrollmentFailed),
      (403, #"{"code":"machineNotAuthorized"}"#, .enrollmentFailed),
      (503, #"{"code":"machineNotAuthorized"}"#, .serverUnavailable),
    ]
    for (status, body, expected) in cases {
      let connector = WebSocketConnector { _ in throw WebSocketError.refused(status: status, headers: Headers(), body: Array(body.utf8)) }
      do {
        _ = try await MachineV2Runtime.connect(home: home, trust: .init(directory: root), fetch: fetch, connector: connector)
        Issue.record("HTTP \(status) \(body) connected")
      } catch let error as MachineV2RuntimeError {
        #expect(error.code == expected, "HTTP \(status) \(body)")
      }
    }
  }

  @Test func acknowledgedLeaveKeepsControlOwnerAliveButNeverRedials() async throws {
    let calls = Mutex(0); let acknowledged = Mutex(false); let sleeps = Mutex(0)
    let clock = OperationClock(now: { .zero }, sleep: { _ in
      let count = sleeps.withLock { $0 += 1; return $0 }
      if count >= 3 { throw CancellationError() }
    })
    do {
      try await MachineV2Runtime.dialLoop(handler: { _ in .text("unused") }, leaveAcknowledged: { acknowledged.withLock { $0 } }, connect: {
        calls.withLock { $0 += 1 }
        return TunnelTransport(receive: { acknowledged.withLock { $0 = true }; return nil }, send: { _ in }, abort: {})
      }, clock: clock)
    } catch is CancellationError {}
    #expect(acknowledged.withLock { $0 })
    #expect(calls.withLock { $0 } == 1)
    #expect(sleeps.withLock { $0 } == 3)
  }

  @Test func localLeaveDecodesBoundedJSONBooleanAndRejectsMalformedReceipts() async throws {
    for literal in ["true", " \ttrue\r\n"] {
      let response = Response(status: .ok, body: .bytes(Data(literal.utf8), contentType: "application/json"))
      try await MachineV2Runtime.validateLeaveResponse(response)
    }
    for literal in ["false", "", "tru", "true false", "{\"left\":true}", "null"] {
      do {
        try await MachineV2Runtime.validateLeaveResponse(Response(status: .ok, body: .bytes(Data(literal.utf8))))
        Issue.record("malformed or negative receipt accepted: \(literal)")
      } catch let error as MachineV2RuntimeError { #expect(error.code == .drainFailed) }
    }
    let drain = try Response.json(ErrorEnvelope(.init(.requestDeadline, message: "drainFailed")), status: .badRequest)
    do { try await MachineV2Runtime.validateLeaveResponse(drain); Issue.record("expected drain failure") }
    catch let error as MachineV2RuntimeError { #expect(error.code == .drainFailed) }
    let ack = try Response.json(ErrorEnvelope(.init(.requestDeadline, message: "leaveUnacknowledged")), status: .badRequest)
    do { try await MachineV2Runtime.validateLeaveResponse(ack); Issue.record("expected ack failure") }
    catch let error as MachineV2RuntimeError { #expect(error.code == .leaveUnacknowledged) }
  }

  @Test func productionLeaveUsesCompleteHTTPHeadAndDecodesActualUnixWireReplies() async throws {
    if !LeakGuard.isChild {
      let run = try await LeakGuard.run(filter: "productionLeaveUsesCompleteHTTPHeadAndDecodesActualUnixWireReplies", environment: ["TMPDIR": "/tmp"])
      #expect(run.status == 0, "\(run.output)")
      #expect(run.ran > 0, "\(run.output)")
      #expect(run.leftovers == [], "\(run.output)")
      return
    }
    let fixture = try fixture("leave"); defer { fixture.scratch.remove() }
    let home = MachineV2Home(root: fixture.root, machine: "test")
    try #require(home.socket.path.utf8.count < 104)
    try home.prepare()
    let calls = Mutex(0)
    let server = try await ServeNIOServer.bind(unixDomainSocketPath: home.socket.path) { request in
      #expect(request.method == .put)
      #expect(request.url.path == "/leave")
      #expect(request.headers["Host"] == "localhost")
      #expect((try await request.body?.bytes(upTo: 32).count) ?? 0 == 0)
      let index = calls.withLock { $0 += 1; return $0 }
      switch index {
      case 1: return try .json(true)
      case 2: return try .json(false)
      case 3: return try .json(ErrorEnvelope(.init(.requestDeadline, message: "drainFailed")), status: .badRequest)
      default: return try .json(ErrorEnvelope(.init(.requestDeadline, message: "leaveUnacknowledged")), status: .badRequest)
      }
    }
    #expect(chmod(home.socket.path, 0o600) == 0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.runUntilCancelled() }
      do {
        try await MachineV2Runtime.leave(home: home)
        for expected in [MachineV2RuntimeError.Code.drainFailed, .drainFailed, .leaveUnacknowledged] {
          do { try await MachineV2Runtime.leave(home: home); Issue.record("negative wire response accepted") }
          catch let error as MachineV2RuntimeError { #expect(error.code == expected) }
        }
      } catch { await server.shutdown(); group.cancelAll(); throw error }
      await server.shutdown(); group.cancelAll()
    }
    #expect(calls.withLock { $0 } == 4)
  }

  @Test func revocationRetiresRecordsAndEndsCleanlyForTheServiceManager() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }
    let home = MachineV2Home(root: fixture.root, machine: "test")
    try home.prepare()
    let retired = Mutex(0)
    for failure in [MachineV2RuntimeError(.enrollmentFailed), MachineV2RuntimeError(.invalidConfiguration)] {
      do {
        try await MachineV2Runtime.retiringOnRevoke(home: home, retire: { retired.withLock { $0 += 1 } }) { throw failure }
        Issue.record("failure swallowed")
      } catch let error as MachineV2RuntimeError { #expect(error == failure) }
      #expect(MachineV2Runtime.exitStatus(for: failure) == 1)
    }
    #expect(retired.withLock { $0 } == 0)
    #expect(!home.isRevoked)
    do {
      try await MachineV2Runtime.retiringOnRevoke(home: home, retire: { retired.withLock { $0 += 1 } }) { throw MachineV2RuntimeError(.revoked) }
      Issue.record("revocation swallowed")
    } catch let error as MachineV2RuntimeError {
      #expect(error.code == .revoked)
      #expect(MachineV2Runtime.exitStatus(for: error) == 0)
    }
    #expect(retired.withLock { $0 } == 1)
    #expect(home.isRevoked)
    #expect(MachineV2Runtime.exitStatus(for: CancellationError()) == 1)
    try home.clearRevoked()
    #expect(!home.isRevoked)
    try home.clearRevoked()
  }

  /// Inside its job a revoked agent never trusts the loaded definition to keep a clean exit down: it stops the job, or
  /// parks idle until a signal ends it. Any other failure leaves the job alone.
  @Test(arguments: [true, false]) func aRevokedJobStopsItselfOrParks(stops: Bool) async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }
    let home = MachineV2Home(root: fixture.root, machine: "test")
    try home.prepare()
    let steps = Mutex<[String]>([])
    let clock = OperationClock(now: { .zero }, sleep: { _ in
      try steps.withLock {
        $0.append("park")
        if $0.count(where: { $0 == "park" }) == 3 { throw CancellationError() }
      }
    })
    let service = MachineV2Service(stop: {
      steps.withLock { $0.append("stop") }
      if !stops { throw MachineV2InstallError(code: .serviceFailure, message: "systemctl stop: no bus") }
    })
    do {
      try await MachineV2Runtime.retiringOnRevoke(home: home, service: service, clock: clock, retire: {}) { throw MachineV2RuntimeError(.serverUnavailable) }
    } catch let error as MachineV2RuntimeError { #expect(error.code == .serverUnavailable) }
    #expect(steps.withLock { $0 }.isEmpty)
    do {
      try await MachineV2Runtime.retiringOnRevoke(home: home, service: service, clock: clock, retire: { steps.withLock { $0.append("retire") } }) { throw MachineV2RuntimeError(.revoked) }
      Issue.record("revocation swallowed")
    } catch let error as MachineV2RuntimeError {
      #expect(stops && error.code == .revoked)
    } catch is CancellationError {
      #expect(!stops)
    }
    #expect(steps.withLock { $0 } == ["retire", "stop"] + (stops ? [] : ["park", "park", "park"]))
    #expect(home.isRevoked)
    let log = try String(contentsOf: home.upgradeLog, encoding: .utf8)
    #expect(log.contains("revoked; stopping the service job"))
    #expect(log.contains("revoked; parked") == !stops)
  }

  @Test func uninstallDrainsALiveAgentButNotARevokedOne() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }
    let home = MachineV2Home(root: fixture.root, machine: "test")
    try home.prepare()
    do { try await MachineV2Runtime.leaveForUninstall(home: home); Issue.record("missing agent drained") }
    catch let error as MachineV2RuntimeError { #expect(error.code == .drainFailed) }
    try home.markRevoked()
    try await MachineV2Runtime.leaveForUninstall(home: home)
  }

  @Test func refusedV1TokenNeverWritesEitherMachineHome() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let effects = EnrollmentEffects(refuseV2: true)
    do {
      _ = try await MachineV2Runtime.join(server: "https://example.test", fingerprint: nil, name: "box", token: "explicit-token", environment: ["HOME": root.path], trust: .init(directory: root), fetch: effects.client)
      Issue.record("refusal must propagate")
    } catch let error as MachineV2RuntimeError { #expect(error.code == .enrollmentFailed) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".wuhu/machine-v2").path))
    #expect(await effects.requests.count == 1)
  }

  @Test func homeRejectsUnsafeIDsLooseKeysAndSymlinkState() throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    #expect(throws: MachineV2RuntimeError.self) { try MachineV2Home(root: root, machine: "../v1").validate() }
    let home = MachineV2Home(root: root, machine: "test")
    try home.save(.init(machine: "test", name: "box-v2", server: "https://example.test"), key: .init())
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.keyFile.path)
    #expect(throws: MachineV2RuntimeError.self) { _ = try home.loadKey() }
    try FileManager.default.removeItem(at: home.operationsDirectory)
    try FileManager.default.createSymbolicLink(at: home.operationsDirectory, withDestinationURL: root)
    #expect(throws: MachineV2RuntimeError.self) { try home.prepare() }
  }

  @Test func launchdPreflightWritesTypedFailureWithoutAlternativeTransport() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let home = MachineV2Home(root: root, machine: "test")
    try home.save(.init(machine: "test", name: "box-v2", server: "https://example.test"), key: .init())
    let output = home.directory.appendingPathComponent("receipt.json")
    let fetch = FetchClient { _ in throw MachineV2RuntimeError(.localNetworkDenied, message: "injected grant denial") }
    try await MachineV2Runtime.preflight(home: home, trust: .init(directory: root), fetch: fetch, result: output)
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output))
    #expect(json.object?["ok"] == false)
    #expect(json.object?["code"] == "localNetworkDenied")
  }

  @Test func recordingIsIncrementalPrivateAndScrubsCredentialFields() async throws {
    let fixture = try fixture(); defer { fixture.scratch.remove() }; let root = fixture.root
    let recorder = try MachineV2Recording(root: root)
    let handler = recorder.handler { _ in try .json(JSONValue.object(["verdict": "safe"])) }
    var request = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(JSONValue.object(["kind": "exec.v1", "input": ["argv": ["/bin/echo", "safe"], "env": ["TOKEN": "do-not-record"], "sessionCredential": ["token": "do-not-record"], "secretValues": ["secret": "do-not-record"]]])))
    request.headers["Authorization"] = "do-not-record"
    #expect(try await handler(request).status.code == 200)
    let directory = await recorder.directory
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let recording = try JSONDecoder().decode(ExchangeRecording.self, from: Data(contentsOf: files[0]))
    let body = String(decoding: recording.exchanges[0].request.body!, as: UTF8.self)
    #expect(!body.contains("do-not-record"))
    #expect(recording.exchanges[0].request.headers["authorization"] == nil)
    #expect(recording.exchanges.count == 1)
    #expect(recording.effects.count == 1)
    let replay = FetchExchangeRecorder(replay: recording)
    var safe = request; safe.headers = .init(); safe.body = .bytes(recording.exchanges[0].request.body!, contentType: "application/json")
    #expect(try await replay.client(safe).status.code == 200)
  }
}

extension MachineV2RuntimeTests {
  @Test(arguments: ["join", "preflight"])
  func sessionRefusalExplainsPersonActionAndExactWalletOptInBeforeEffects(_ verb: String) async throws {
    let effects = Mutex(0)
    do {
      _ = try await MachineV2Runtime.command(arguments: ["machine-v2", verb], environment: ["WUHU_EXEC": "1", "WUHU_TOKEN": "session-token", "WUHU_SPACE_URL": "https://example.test"], fetch: .init { _ in effects.withLock { $0 += 1 }; return .text("unreachable") }, stdin: { effects.withLock { $0 += 1 }; return "unreachable" }, stdout: { _ in effects.withLock { $0 += 1 } })
      Issue.record("session identity accepted")
    } catch let error as CLIError {
      #expect(error.message.contains("person action"))
      #expect(error.message.contains("WUHU_IDENTITY=wallet wuhu machine-v2 \(verb)"))
      #expect(!error.message.contains("session-token"))
    }
    #expect(effects.withLock { $0 } == 0)
  }
}
