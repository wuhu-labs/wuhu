#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CExecSupervisor
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
import Testing

private actor SupervisorFixture {
  var manifests: [String: SupervisorManifest] = [:]
  var requests: [Request] = []
  var launches = 0
  var identityMismatch = false
  var reservation = 0
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
    if request.url.path.contains("/inputs/") { return try .json(WriteReceipt(acceptedThrough: .zero, end: false, blocked: false)) }
    return try .json(OperationSnapshot(operation: manifest.operation, verdict: Verdict(.completed, result: .null), terminalToken: UUID(), finalOffsets: ["stdout": .zero, "stderr": .zero], outputConsumed: true, bufferReservationBytes: reservation))
  }

  nonisolated var files: SupervisorFiles { .init(create: { await self.create($0, $1) }, load: { try await self.load($0) }, list: { _ in await self.directories() }) }
  nonisolated func registry(probe: Bool = false) throws -> ExecSupervisorRegistry {
    try .init(machine: "test", operationsDirectory: "/tmp/ops", executable: "/tmp/wuhu", fetch: FetchClient { try await self.fetch($0) }, authorize: { _, _ in }, files: files, clock: .continuous, launch: { _, _ in if probe { return try await self.launchProbe() }; await self.launch(); return nil })
  }
}

@Suite struct RegistryContractTests {
  @Test func machineMismatchIsTypedPerEntryWithItsPath() async throws {
    let effects = SupervisorFixture(); let first = try effects.registry(); let healthy = UUID(); let changed = UUID()
    for id in [healthy, changed] {
      _ = try await first.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh"], "cwd": "/tmp", "stdin": false]))))
    }
    await effects.changeMachine(changed)
    let recovered = try effects.registry(); try await recovered.recover()
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
    let recovered = try effects.registry()
    try await recovered.recover()
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
    let recovered = try effects.registry(); try await recovered.recover()
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
    let recovered = try effects.registry(); try await recovered.recover()
    #expect(try await recovered.handler(Request(url: URL(string: "http://memory/machine/v2/machines/test")!)).status.code == 200)
    let response = try await recovered.handler(execRequest(id))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .supervisorIdentityMismatch)
    #expect(await effects.launches == 1)
  }
}
