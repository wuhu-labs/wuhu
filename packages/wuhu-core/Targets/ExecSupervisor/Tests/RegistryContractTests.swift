#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CExecSupervisor
@testable import ComputerFiles
@testable import ExecSupervisor
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteReceipt
import Synchronization
import Testing

private actor SupervisorFixture {
  var manifests: [String: SupervisorManifest] = [:]
  var requests: [Request] = []
  var launches = 0
  var identityMismatch = false
  var reservation = 0
  var capabilityStatus = 200
  var drained = true
  var terminal = true
  let terminalToken = UUID()
  var rejectAck = false
  func rejectAcknowledgements(_ rejected: Bool) { rejectAck = rejected }
  var reason: String?
  func expiredReceipt(drained: Bool = false) { capabilityStatus = 404; self.drained = drained; terminal = true; reason = "leaseExpired" }
  var malformedDeparture: String?
  func remainRunning() { terminal = false }
  func malformedReceipt(_ literal: String) { malformedDeparture = literal }
  func capability(_ status: Int, drained: Bool = true) { capabilityStatus = status; self.drained = drained }
  func consumeOutput() { drained = true }
  var childPID: Int32?
  func launchProbe() throws -> Int32? {
    var pid: Int32 = 0
    guard exec_launch_supervisor("/usr/bin/true", "/tmp/probe", &pid) == 0 else { throw OperationError(.spawnFailed) }
    childPID = pid; return pid
  }

  var torn: Set<String> = []
  var hung = false
  func addTorn(_ id: UUID) { torn.insert("/tmp/ops/" + id.uuidString) }
  func hangIdentities() { hung = true }
  func mismatch() { identityMismatch = true }
  func changeMachine(_ id: UUID) {
    let directory = "/tmp/ops/" + id.uuidString; let value = manifests[directory]!
    manifests[directory] = SupervisorManifest(version: value.version, machine: "other", operation: value.operation, nonce: value.nonce, socket: value.socket)
  }

  func retainInput() { reservation = 64 * 1024 }
  func removeAll() { manifests = [:] }
  func create(_ directory: String, _ manifest: SupervisorManifest) { manifests[directory] = manifest }
  func load(_ directory: String) throws -> SupervisorManifest {
    guard let manifest = manifests[directory] else { throw OperationError(.invalidConfiguration) }; return manifest
  }

  func directories() -> [String] { Array(manifests.keys) + Array(torn) }
  func launch() { launches += 1 }
  func fetch(_ request: Request) async throws -> Response {
    requests.append(request)
    let manifest = try #require(manifests.values.first { request.headers["X-Wuhu-Supervisor-Nonce"] == $0.nonce })
    #expect(request.headers["Host"] == "localhost")
    if request.url.path == "/identity" {
      if hung { try await ContinuousClock().sleep(for: .seconds(2)) }
      if identityMismatch { return .text("wrong", status: .forbidden) }
      var response = try Response.json(manifest)
      response.headers[.init("X-Wuhu-Supervisor-Active")!] = "0"
      response.headers[.init("X-Wuhu-Supervisor-Reservation")!] = String(reservation)
      return response
    }
    if request.url.path == "/leave" || request.url.path == "/departure" {
      if capabilityStatus == 200 {
        if request.url.path == "/departure", let malformedDeparture { return Response(status: .ok, body: .bytes(Data(malformedDeparture.utf8), contentType: "application/json")) }
        return try .json(true)
      }
      return try .json(ErrorEnvelope(.init(capabilityStatus == 404 ? .unknownOperation : .machineNotAuthorized)), status: .init(code: capabilityStatus))
    }
    if request.url.path.contains("/inputs/") { return try .json(WriteReceipt(acceptedThrough: .zero, end: false, blocked: false)) }
    if request.method == .get, let raw = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "terminalAck" })?.value {
      if rejectAck || UUID(uuidString: raw) != terminalToken { return try .json(ErrorEnvelope(.init(.invalidInput)), status: .badRequest) }
    }
    return try .json(OperationSnapshot(operation: manifest.operation, verdict: terminal ? Verdict(reason == nil ? .completed : .stopped, result: .null, reason: reason) : nil, terminalToken: terminal ? terminalToken : nil, finalOffsets: ["stdout": .zero, "stderr": .zero], outputConsumed: drained, bufferReservationBytes: reservation))
  }

  nonisolated var files: SupervisorFiles { .init(create: { await self.create($0, $1) }, load: { try await self.load($0) }, list: { _ in await self.directories() }) }
  /// A launched version-2 supervisor dials the agent; the fixture answers its operation over that link.
  nonisolated func registry(disclaimResponsibility: Bool = false, probe: Bool = false, clock: OperationClock = .continuous, root: String = "/tmp/ops") throws -> ExecSupervisorRegistry {
    let launched = RegistryHolder()
    let registry = try ExecSupervisorRegistry(machine: "test", operationsDirectory: root, executable: "/tmp/wuhu", fetch: FetchClient { try await self.fetch($0) }, authorize: { _, _ in }, files: files, clock: clock, disclaimResponsibility: disclaimResponsibility, launch: { _, directory in
      let pid = probe ? try await self.launchProbe() : nil
      if !probe { await self.launch() }
      if let registry = launched.registry.withLock({ $0 }) { try await self.dial(registry, directory: directory) }
      return pid
    })
    launched.registry.withLock { $0 = registry }
    return registry
  }

  /// A restarted agent: recovers the manifests, then every surviving version-2 supervisor redials it.
  nonisolated func recovered(root: String = "/tmp/ops") async throws -> ExecSupervisorRegistry {
    let registry = try registry(root: root)
    try await registry.recover()
    for directory in await Array(manifests.keys) { try? await dial(registry, directory: directory) }
    return registry
  }

  func dial(_ registry: ExecSupervisorRegistry, directory: String) async throws {
    guard let manifest = manifests[directory], manifest.version == 2 else { return }
    let hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: manifest.machine, operation: manifest.operation, nonce: manifest.nonce)
    _ = try await registry.link(hello, client: FetchClient { try await self.fetch($0) }, abort: {})
  }
}

private final class RegistryHolder: Sendable { let registry = Mutex<ExecSupervisorRegistry?>(nil) }
private final class RegistryAborted: Sendable { let value = Mutex(false) }

@Suite struct RegistryContractTests {
  @Test(arguments: [false, true]) func responsibilityPolicyPersistsInThePrivateManifest(disclaim: Bool) async throws {
    let effects = SupervisorFixture()
    let registry = try effects.registry(disclaimResponsibility: disclaim)
    let id = UUID()
    let response = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false, "disclaimResponsibility": .bool(!disclaim)]))))
    #expect(response.status.code == 200)
    let manifest = try await effects.load("/tmp/ops/" + id.uuidString)
    #expect(manifest.disclaimResponsibility == (disclaim ? true : nil))
    let recovered = try JSONDecoder().decode(SupervisorManifest.self, from: JSONEncoder().encode(manifest))
    #expect(recovered == manifest)
    #expect(try await effects.recovered().handler(execRequest(id)).status.code == 200)
  }

  @Test func legacyManifestKeepsInheritedResponsibility() throws {
    let id = UUID()
    let bytes = Data("""
    {"version":2,"machine":"test","operation":"\(id)","nonce":"\(String(repeating: "n", count: 72))","socket":"/tmp/ctl.sock"}
    """.utf8)
    let manifest = try JSONDecoder().decode(SupervisorManifest.self, from: bytes)
    try validateManifest(manifest, directory: "/tmp/ops/" + id.uuidString)
    #expect(manifest.disclaimResponsibility == nil)
  }

  @Test func newStartsNameTheMachineRendezvousSocketAndReattachAfterRestart() async throws {
    let root = "/Users/someone/.wuhu/machine-v2/mc_fixture01/operations"
    let effects = SupervisorFixture(); let registry = try effects.registry(root: root); let id = UUID()
    let response = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    #expect(response.status.code == 200)
    let directory = root + "/" + id.uuidString
    let manifest = try await effects.load(directory)
    #expect(manifest.version == 2)
    #expect(manifest.socket == "/Users/someone/.wuhu/machine-v2/mc_fixture01/ctl.sock")
    #expect(!manifest.socket.hasPrefix(directory), "no per-operation socket")
    let requests = await effects.requests
    #expect(requests.allSatisfy { $0.url.absoluteString.hasPrefix("http://localhost/") }, "version 2 goes over the link, never a Unix URL")
    let recovered = try await effects.recovered(root: root)
    #expect(try await recovered.handler(execRequest(id)).status.code == 200)
    #expect(await effects.launches == 1)
  }

  @Test func unlinkedVersionTwoSupervisorIsTypedUnavailableNeverRelaunched() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let id = UUID()
    _ = try await first.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    let recovered = try effects.registry(); try await recovered.recover()
    let clock = ContinuousClock(); let began = clock.now
    let failure = try await recovered.handler(execRequest(id)).body.json(ErrorEnvelope.self).error
    #expect(failure.code == .supervisorUnavailable)
    #expect(failure.message == "supervisorNotConnected")
    #expect(clock.now - began < .seconds(4))
    #expect(await effects.launches == 1)
    #expect(await effects.requests.filter { $0.method == .post }.count == 1)
  }

  @Test func rendezvousAdmitsOnlyAKnownVersionTwoOperationWithItsNonce() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    let manifest = try await effects.load("/tmp/ops/" + id.uuidString)
    let legacy = UUID(); let legacyDirectory = "/tmp/ops/" + legacy.uuidString
    let legacyManifest = SupervisorManifest(version: 1, machine: "test", operation: legacy, nonce: UUID().uuidString + UUID().uuidString, socket: legacyDirectory + "/control.sock")
    await effects.create(legacyDirectory, legacyManifest)
    let recovered = try effects.registry(); try await recovered.recover()
    func hello(_ edit: (inout Rendezvous.Hello) -> Void = { _ in }) -> Rendezvous.Hello {
      var value = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: "test", operation: id, nonce: manifest.nonce); edit(&value); return value
    }
    let cases: [(Rendezvous.Hello, Rendezvous.Refusal)] = [
      (hello { $0.nonce = UUID().uuidString + UUID().uuidString }, .nonceMismatch),
      (hello { $0.nonce = String(manifest.nonce.dropLast()) }, .nonceMismatch),
      (hello { $0.operation = UUID() }, .unknownOperation),
      (hello { $0.machine = "other" }, .machineMismatch),
      (hello { $0.protocol = "wuhu-supervisor-rendezvous.v0" }, .unsupportedProtocol),
      (hello { $0.operation = legacy; $0.nonce = legacyManifest.nonce }, .manifestVersion),
    ]
    for (hello, refusal) in cases {
      do { _ = try await recovered.link(hello, client: FetchClient { _ in throw OperationError(.invalidResponse) }, abort: {}); Issue.record("admitted \(hello)") }
      catch { #expect(error == refusal) }
    }
    #expect(await recovered.links.isEmpty)
    #expect(!Rendezvous.peerAllowed(UInt32(getuid()) &+ 1))
    #expect(Rendezvous.peerAllowed(UInt32(getuid())))
    let aborted = RegistryAborted()
    let first = try await recovered.link(hello(), client: FetchClient { _ in throw OperationError(.invalidResponse) }, abort: { aborted.value.withLock { $0 = true } })
    let second = try await recovered.link(hello(), client: FetchClient { try await effects.fetch($0) }, abort: {})
    #expect(second > first)
    #expect(aborted.value.withLock { $0 }, "a redial replaces and closes the older link")
    await recovered.unlink(id, generation: first)
    #expect(try await recovered.handler(execRequest(id)).status.code == 200, "the newest link wins and a stale unlink leaves it")
  }

  @Test func legacyControlSocketManifestRecoversWithoutRelaunch() async throws {
    let effects = SupervisorFixture(); let id = UUID(); let directory = "/tmp/ops/" + id.uuidString
    let manifest = SupervisorManifest(version: 1, machine: "test", operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: directory + "/control.sock")
    await effects.create(directory, manifest)
    let recovered = try effects.registry()
    try await recovered.recover()
    #expect(try await recovered.handler(execRequest(id)).status.code == 200)
    #expect(await effects.launches == 0)
    let requests = await effects.requests
    #expect(requests.contains { $0.url.path == "/identity" })
    #expect(requests.allSatisfy { $0.url.host?.removingPercentEncoding == manifest.socket })
    try await recovered.leave()
    #expect(try await recovered.departureSettled())
  }

  @Test func manifestSocketValidationAcceptsOnlyExactBoundedBasenames() throws {
    let id = UUID(); let nonce = UUID().uuidString + UUID().uuidString
    let directory = "/tmp/ops/" + id.uuidString
    for suffix in ["/s", "/control.sock"] {
      try validateManifest(SupervisorManifest(version: 1, machine: "test", operation: id, nonce: nonce, socket: directory + suffix), directory: directory)
    }
    for socket in [directory + "/other", directory + "/../s", "/tmp/s"] {
      #expect(throws: OperationError.self) { try validateManifest(SupervisorManifest(version: 1, machine: "test", operation: id, nonce: nonce, socket: socket), directory: directory) }
    }
    for count in [103, 104] {
      let padded = "/" + String(repeating: "x", count: count - 40) + "/" + id.uuidString
      let manifest = SupervisorManifest(version: 1, machine: "test", operation: id, nonce: nonce, socket: padded + "/s")
      #expect(manifest.socket.utf8.count == count)
      if count == 103 { try validateManifest(manifest, directory: padded) }
      else { #expect(throws: OperationError.self) { try validateManifest(manifest, directory: padded) } }
    }
    let machine = "/home/someone/.wuhu/machine-v2/mc_fixture01"; let modern = machine + "/operations/" + id.uuidString
    try validateManifest(SupervisorManifest(version: 2, machine: "test", operation: id, nonce: nonce, socket: machine + "/ctl.sock"), directory: modern)
    for socket in [modern + "/control.sock", modern + "/s", machine + "/operations/ctl.sock", "/tmp/ctl.sock"] {
      #expect(throws: OperationError.self) { try validateManifest(SupervisorManifest(version: 2, machine: "test", operation: id, nonce: nonce, socket: socket), directory: modern) }
    }
    #expect(throws: OperationError.self) { try validateManifest(SupervisorManifest(version: 3, machine: "test", operation: id, nonce: nonce, socket: machine + "/ctl.sock"), directory: modern) }
  }

  @Test func explicitLegacy404DrainsThroughExistingOperationStopAndRetainedReceipt() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.capability(404, drained: false)
    try await registry.leave()
    #expect(!(try await registry.departureSettled()))
    #expect(await effects.requests.filter { $0.url.path.hasSuffix("/stop") }.count == 1)
    await effects.consumeOutput()
    _ = try await registry.handler(ackRequest(id, token: effects.terminalToken))
    #expect(try await registry.departureSettled())
    #expect(await effects.requests.filter { $0.method == .post }.count == 1)
    #expect(await effects.requests.filter { $0.url.path == "/departure" }.isEmpty)
  }

  @Test func legacyDrainRequiresAcceptedMatchingTerminalAcknowledgement() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.capability(404)
    try await registry.leave()
    #expect(!(try await registry.departureSettled()))
    #expect(try await registry.handler(ackRequest(id, token: UUID())).status.code == 400)
    #expect(!(try await registry.departureSettled()))
    await effects.rejectAcknowledgements(true)
    let token = effects.terminalToken
    #expect(try await registry.handler(ackRequest(id, token: token)).status.code == 400)
    #expect(!(try await registry.departureSettled()))
    await effects.rejectAcknowledgements(false)
    #expect(try await registry.handler(ackRequest(id, token: token)).status.code == 200)
    #expect(try await registry.departureSettled())
  }

  @Test func acceptedAcknowledgementBeforeLegacyDiscoveryIsRetained() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    #expect(try await registry.handler(ackRequest(id, token: effects.terminalToken)).status.code == 200)
    await effects.capability(404)
    try await registry.leave()
    #expect(try await registry.departureSettled())
  }

  @Test func leaseExpiredAlwaysRemainsLossEvenWithConsumedOutputAndAcceptedAck() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.expiredReceipt(drained: true)
    #expect(try await registry.handler(ackRequest(id, token: effects.terminalToken)).status.code == 200)
    try await registry.leave()
    #expect(!(try await registry.departureSettled()))
    if case let .leaseExpired(ids) = try await registry.departureEvidence() { #expect(ids == [id]) }
    else { Issue.record("expired verdict became a clean departure") }
  }

  @Test func unresolvedReceiptDisappearanceRetainsTypedUnacknowledgedEvidence() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.capability(404)
    try await registry.leave()
    await effects.removeAll()
    for _ in 0 ..< 2 {
      do { _ = try await registry.departureEvidence(); Issue.record("disappearance became clean proof") }
      catch let error as OperationError {
        #expect(error.code == .supervisorUnavailable)
        #expect(error.message == "legacyReceiptDisappeared")
        #expect(error.operation == id)
        #expect(error.details == ["reason": "localReceiptDisappearance", "unacknowledged": true, "cleanupAuthorized": false])
      }
    }
    #expect(await registry.legacyDepartures[id] != nil)
    #expect(await registry.owns(id))
    #expect(await registry.terminalAcknowledgements[id] == nil)
  }

  @Test func disappearanceCannotEraseAlreadyObservedLeaseLoss() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.expiredReceipt(drained: true)
    try await registry.leave()
    await effects.removeAll()
    if case let .leaseExpired(ids) = try await registry.departureEvidence() { #expect(ids == [id]) }
    else { Issue.record("observed loss disappeared") }
    #expect(!(try await registry.departureSettled()))
  }

  @Test func legacyLeaseDurationNeverInventsTerminalEvidence() async throws {
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { _ in })
    let effects = SupervisorFixture(); let registry = try effects.registry(clock: clock); let id = UUID()
    await effects.remainRunning()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.capability(404)
    try await registry.leave()
    now.withLock { $0 = .seconds(61) }
    #expect(!(try await registry.departureSettled()))
    #expect(await effects.requests.filter { $0.method == .post }.count == 1)
    #expect(await effects.requests.filter { $0.method == .get && $0.url.path.contains("/operations/") }.count == 1)
  }

  @Test func observedLegacyLeaseExpiryIsTypedLossNeverCleanGoodbyeOrConsumption() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.expiredReceipt()
    let agent = try ComputerAgent(machine: "test", external: registry.external)
    let response = try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put))
    let error = try await response.body.json(ErrorEnvelope.self).error
    #expect(error.code == .requestDeadline)
    #expect(error.message == "leaveUnacknowledged")
    #expect(error.operation == id)
    #expect(error.details == ["reason": "legacyLeaseExpired", "operations": [.string(id.uuidString)]])
    #expect(!(await agent.leaveAcknowledged))
    #expect(!(await agent.drainCompleted))
    #expect(!(try await registry.departureSettled()))
    let describe = Request(url: URL(string: "http://agent/machine/v2/machines/test?leaveAck=true")!)
    #expect(try await agent.handler(describe).body.json(ErrorEnvelope.self).error.code != .leaving)
    #expect(!(await agent.leaveAcknowledged))
  }

  @Test func legacyExpiryProofCannotAuthorizeCleanupWhileAnotherKindIsUnsettled() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.expiredReceipt()
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { duration in
      if duration >= .seconds(1) { now.withLock { $0 += duration }; return }
      try await ContinuousClock().sleep(for: .milliseconds(1))
    })
    let agent = try ComputerAgent(machine: "test", external: registry.external, clock: clock)
    let fileRequest = Request(url: URL(string: "http://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(StartRequest(kind: "read.v1", input: ["path": "/tmp/not-run"])))
    #expect(try await agent.runtime.handler(fileRequest).status.code == 201)
    let response = try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put))
    #expect(try await response.body.json(ErrorEnvelope.self).error.message == "drainFailed")
    #expect(await agent.departureLoss == nil)
    #expect(!(await agent.leaveAcknowledged))
    await agent.shutdown()
  }

  @Test func malformedModernDepartureReceiptIsTypedAndNeverLegacy() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    try await registry.leave()
    await effects.malformedReceipt("tru")
    do { _ = try await registry.departureSettled(); Issue.record("malformed receipt accepted") }
    catch let error as OperationError { #expect(error.code == .invalidResponse) }
    #expect(await effects.requests.filter { $0.url.path.hasSuffix("/stop") }.isEmpty)
  }

  @Test func non404CapabilityFailureNeverSelectsLegacyBehavior() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false]))))
    await effects.capability(403)
    do { try await registry.leave(); Issue.record("capability refusal must be typed") }
    catch let error as OperationError { #expect(error.code == .supervisorUnavailable) }
    #expect(await effects.requests.filter { $0.url.path.hasSuffix("/stop") }.isEmpty)
  }

  @Test func machineMismatchIsTypedPerEntryWithItsPath() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let healthy = UUID(); let changed = UUID()
    for id in [healthy, changed] {
      _ = try await first.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    }
    await effects.changeMachine(changed)
    let recovered = try await effects.recovered()
    #expect(try await recovered.handler(execRequest(healthy)).status.code == 200)
    let failure = try await recovered.handler(execRequest(changed)).body.json(ErrorEnvelope.self).error
    #expect(failure.code == .supervisorIdentityMismatch)
    #expect(failure.details == ["path": .string("/tmp/ops/" + changed.uuidString + "/manifest.json")])
  }

  @Test func corruptManifestDecoderReturnsTypedPathInsteadOfDecodingError() async throws {
    let directory = "/tmp/w96-corrupt-" + UUID().uuidString.prefix(8)
    let id = UUID(); let path = directory + "/" + id.uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let manifest = SupervisorManifest(version: 1, machine: "test", operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: path + "/control.sock")
    try await SupervisorFiles.live.create(path, manifest)
    try Data("{invalid".utf8).write(to: URL(fileURLWithPath: path + "/manifest.json"))
    do { _ = try await SupervisorFiles.live.load(path); Issue.record("corrupt manifest decoded") }
    catch let error as OperationError {
      #expect(error.code == .invalidConfiguration)
      #expect(error.details == ["path": .string(path + "/manifest.json")])
    } catch { Issue.record("raw decode error escaped: \(error)") }
  }

  @Test func exitedSupervisorIsReapedByTheAgentLifecycle() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(probe: true); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    let pid = try #require(await effects.childPID)
    defer { _ = exec_signal_group(pid, SIGKILL); _ = exec_reap(pid) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await registry.run() }
      let clock = ContinuousClock(); let deadline = clock.now + .seconds(2)
      var tag: Int32 = 0; var value: Int32 = 0
      while clock.now < deadline && exec_observe(pid, &tag, &value) >= 0 { try? await clock.sleep(for: .milliseconds(10)) }
      #expect(exec_observe(pid, &tag, &value) == -ECHILD)
      group.cancelAll()
    }
  }

  @Test func tornManifestCannotDisableDescribeOrHealthyOperation() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let healthy = UUID(); let torn = UUID()
    _ = try await first.handler(execRequest(healthy, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    await effects.addTorn(torn)
    let recovered = try await effects.recovered()
    #expect(try await recovered.handler(Request(url: URL(string: "http://memory/machine/v2/machines/test")!)).status.code == 200)
    #expect(try await recovered.handler(execRequest(healthy)).status.code == 200)
    let response = try await recovered.handler(execRequest(torn))
    #expect(response.status.code >= 400)
    #expect(await effects.launches == 1)
  }

  @Test func hungIdentityDiscoveryDoesNotDelayRecoveryOrDescribe() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let id = UUID()
    _ = try await first.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    await effects.hangIdentities()
    let clock = ContinuousClock(); let began = clock.now
    let recovered = try effects.registry(); try await recovered.recover()
    #expect(clock.now - began < .seconds(1))
    #expect(try await recovered.handler(Request(url: URL(string: "http://memory/machine/v2/machines/test")!)).status.code == 200)
  }

  @Test func inputReceiptIsForwardedWithoutSnapshotDecodeAndStartIsNeverReplayed() async throws {
    let effects = SupervisorFixture(); let registry = try effects.registry(); let id = UUID()
    let start = StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": true])
    #expect(try await registry.handler(execRequest(id, method: .post, body: .json(start))).status.code == 200)
    #expect(try await registry.handler(execRequest(id, method: .post, body: .json(start))).status.code == 409)
    #expect(try await registry.handler(execRequest(id, suffix: "/inputs/stdin", method: .put, body: .json(["offset": "0"]))).status.code == 200)
    #expect(await effects.launches == 1)
    #expect(await effects.requests.filter { $0.method == .post }.count == 1)
    let recovered = try await effects.recovered()
    #expect(try await recovered.handler(execRequest(id)).status.code == 200)
    #expect(await effects.launches == 1)
    #expect(await effects.requests.filter { $0.method == .post }.count == 1)
  }

  @Test func terminalInputRemainsChargedAndExpiredReceiptDisappears() async throws {
    let effects = SupervisorFixture(); await effects.retainInput(); let registry = try effects.registry(); let id = UUID()
    _ = try await registry.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": true]))))
    #expect(await registry.reservations[id] == 64 * 1024)
    #expect(await registry.active.isEmpty)
    await effects.removeAll()
    _ = try await registry.handler(Request(url: URL(string: "http://memory/machine/v2/machines/test")!))
    #expect(await registry.reservations.isEmpty)
    let response = try await registry.handler(execRequest(id))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .unknownOperation)
  }

  @Test func recoveryIdentityFailureIsPerOperationAndNeverAdopted() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let id = UUID()
    _ = try await first.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    await effects.mismatch()
    let recovered = try await effects.recovered()
    #expect(try await recovered.handler(Request(url: URL(string: "http://memory/machine/v2/machines/test")!)).status.code == 200)
    let response = try await recovered.handler(execRequest(id))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .supervisorIdentityMismatch)
    #expect(await effects.launches == 1)
  }
}

private func ackRequest(_ operation: UUID, token: UUID) -> Request {
  var request = execRequest(operation)
  request.url = URL(string: request.url.absoluteString + "?terminalAck=" + token.uuidString)!
  return request
}
