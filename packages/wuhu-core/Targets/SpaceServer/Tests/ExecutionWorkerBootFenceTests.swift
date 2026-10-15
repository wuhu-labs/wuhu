#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import SpaceServer
import Synchronization
import Testing
import WorkerProtocol

private final class BootFenceEvents: Sendable {
  private let storage = Mutex<[String]>([])
  func record(_ value: String) { storage.withLock { $0.append(value) } }
  var values: [String] { storage.withLock { $0 } }
}

private func bootManifest() -> ExecutionWorkerManifest {
  .init(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: 123, birth: "worker-process-birth", credentials: .init(current: String(repeating: "a", count: 72), successor: String(repeating: "b", count: 72)))
}

@Test(arguments: [ExecutionWorkerBootFence.Process.absent, .differentBirth])
func bootFenceNeverAuthenticatesOrSignalsAnAbsentOrReusedPID(process: ExecutionWorkerBootFence.Process) async {
  let events = BootFenceEvents()
  let manifest = bootManifest()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["worker"]) }, read: { _ in .manifest(manifest) }, process: { _ in process }, terminate: { _, _ in
    Issue.record("An absent or reused PID must never be authenticated or signalled")
    return .unconfirmed
  }, cleanup: { events.record($0) }, report: { _ in }))
  #expect(events.values == ["worker"])
  #expect(result.unresolved.isEmpty)
  #expect(result.credentials.admits(manifest.credentials.current) == false)
  #expect(result.credentials.admits(manifest.credentials.successor!) == false)
  #expect(result.credentials.admits("fresh-worker-credential"))
}

@Test(arguments: [ExecutionWorkerBootFence.Termination.exited, .staleCredentialExited, .acknowledgedWithoutPIDHandle, .unconfirmed, .unsafeProcessIdentity, .pidHandleUnavailable, .didNotExit])
func bootFenceRequiresAcknowledgedShutdownBeforeRecoveringLiveWorkers(termination: ExecutionWorkerBootFence.Termination) async {
  let events = BootFenceEvents()
  let manifest = bootManifest()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["worker"]) }, read: { _ in .manifest(manifest) }, process: { _ in .matching }, terminate: { _, _ in termination }, cleanup: { events.record($0) }, report: { events.record($0.rawValue) }))
  switch termination {
  case .exited:
    #expect(result.unresolved.isEmpty)
    #expect(events.values == ["terminated", "worker"])
  case .acknowledgedWithoutPIDHandle:
    #expect(result.unresolved.isEmpty)
    #expect(events.values == ["acknowledgedWithoutPIDHandle", "worker"])
  case .unconfirmed:
    #expect(result.unresolved == [manifest.incarnation])
    #expect(events.values == ["unconfirmed"])
  case .staleCredentialExited:
    #expect(result.unresolved.isEmpty)
    #expect(events.values == ["staleCredentialTerminated", "worker"])
  case .unsafeProcessIdentity, .pidHandleUnavailable, .didNotExit:
    #expect(result.unresolved == [manifest.incarnation])
    #expect(events.values.count == 1)
    #expect(events.values.first == result.unresolvedWorkers.first?.reason.rawValue)
  }
}

@Test func bootFenceContinuesAfterPartialFailuresAndKeepsUnverifiedClaims() async {
  let events = BootFenceEvents()
  let first = bootManifest()
  let second = bootManifest()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["first", "second", "third"]) }, read: { directory in .manifest(directory == "first" ? first : second) }, process: { manifest in manifest.incarnation == first.incarnation ? .unverified : .absent }, terminate: { _, _ in .unconfirmed }, cleanup: { directory in
    events.record(directory)
    if directory == "second" { throw CancellationError() }
  }, report: { events.record($0.rawValue) }))
  #expect(result.unresolved == [first.incarnation])
  #expect(result.counts[.unverified] == 1)
  #expect(result.counts[.absent] == 2)
  #expect(result.counts[.cleanupFailed] == 1)
  #expect(events.values == ["unverified", "absent", "second", "cleanupFailed", "absent", "third"])
}

@Test(arguments: [ExecutionWorkerBootFence.Read.missing, .missingManifest, .corrupt, .foreignVersion, .foreignSpace, .unsafeStorage])
func bootFenceUninspectableEvidenceRefusesAdmissionWithoutWriting(read: ExecutionWorkerBootFence.Read) async {
  let events = BootFenceEvents()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["worker"]) }, read: { _ in read }, process: { _ in Issue.record("No identity probe without a valid manifest"); return .unverified }, terminate: { _, _ in Issue.record("No authentication without a valid manifest"); return .unconfirmed }, cleanup: { _ in Issue.record("No writes for a missing or refused manifest") }, report: { events.record($0.rawValue) }))
  if case .missing = read { #expect(result.unresolvedWorkers.isEmpty) }
  else {
    #expect(result.unresolvedWorkers.count == 1)
    #expect(result.unresolvedWorkers.first?.processID == nil)
  }
  #expect(events.values.count == 1)
  #expect(result.counts.values.reduce(0, +) == 1)
}

@Test(arguments: [false, true])
func bootFenceRevocationIsEnforcedAtTheServerAcceptPath(successor: Bool) async throws {
  let manifest = bootManifest()
  let token = successor ? manifest.credentials.successor! : manifest.credentials.current
  let fence = ExecutionWorkerCredentialFence()
  let credentials = try WorkerCredentials(token: token, admission: { fence.admits($0) })
  let hello = WorkerHello(capabilities: WorkerHello.baseline, release: "test")
  let endpoint = WorkerEndpoint(credentials: credentials, hello: hello, invoke: { $0.payload }, upload: { _, _ in }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/worker.sock", token: token, control: fetch, bytes: fetch)
  _ = try await client.negotiate(hello)
  fence.revoke(manifest.credentials)
  await #expect(throws: WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted")) {
    try await client.call(.init(operation: "echo", payload: "must be refused"))
  }
}

@Test func bootFenceMissingInventoryWritesNothing() async {
  let events = BootFenceEvents()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .missing }, read: { _ in Issue.record("Missing inventory cannot be read"); return .missing }, process: { _ in .unverified }, terminate: { _, _ in .unconfirmed }, cleanup: { _ in Issue.record("Missing inventory must not create or remove files") }, report: { events.record($0.rawValue) }))
  #expect(result.counts == [.missing: 1])
  #expect(events.values == ["missing"])
}

@Test func bootFenceOperatorErrorNeverRetainsABearerDisguisedAsABirthIdentity() async {
  let credential = "linux:" + UUID().uuidString + ":" + String(repeating: "7", count: 30)
  let manifest = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: 123, birth: credential, credentials: .init(current: credential))
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["/private/generation"]) }, read: { _ in .manifest(manifest) }, process: { _ in .unverified }, terminate: { _, _ in .unconfirmed }, cleanup: { _ in }, report: { _ in }))
  let error = ExecutionWorkerBootRefusal(workers: result.unresolvedWorkers)
  #expect(!String(describing: error).contains(credential))
  #expect(!String(reflecting: error).contains(credential))
  #expect(!String(reflecting: result.unresolvedWorkers).contains(credential))
}

@Test func bootFenceRejectsUnsafeInventoryWithATypedOperatorFix() async {
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .unsafeStorage("/private/workers") }, read: { _ in Issue.record("Unsafe root cannot be read"); return .missing }, process: { _ in .unverified }, terminate: { _, _ in .unconfirmed }, cleanup: { _ in Issue.record("Unsafe root cannot be changed") }, report: { _ in }))
  #expect(result.counts == [.unsafeStorage: 1])
  await #expect(throws: ExecutionWorkerBootRefusal.self) { try await ExecutionWorkerBootReconciliation.prepare { result } }
  #expect(ExecutionWorkerBootRefusal(workers: result.unresolvedWorkers).description.contains("verify no worker, then remove /private/workers"))
}

@Test func bootFenceProcessesTheRemainingEntriesAfterUninspectableEvidence() async {
  let events = BootFenceEvents()
  let manifest = bootManifest()
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["future", "corrupt", "valid"]) }, read: { directory in
    switch directory { case "future": .foreignVersion; case "corrupt": .corrupt; default: .manifest(manifest) }
  }, process: { _ in .absent }, terminate: { _, _ in .unconfirmed }, cleanup: { events.record($0) }, report: { _ in }))
  #expect(events.values == ["valid"])
  #expect(result.unresolvedWorkers.map(\.directory) == ["future", "corrupt"])
  await #expect(throws: ExecutionWorkerBootRefusal.self) { try await ExecutionWorkerBootReconciliation.prepare { result } }
}
