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

private actor RotationDisk {
  var manifest: ExecutionWorkerManifest
  var failed = false
  var pendingSaves = 0
  var finalSaves = 0

  init(manifest: ExecutionWorkerManifest) { self.manifest = manifest }
  var networkAllowed: Bool { manifest.credentials.successor != nil || finalSaves == 1 }

  func loseResponse(point: String, path: String) -> Bool {
    let matches = (point == "stageReply" && path == "/worker/credentials/stage") || (point == "confirmReply" && path == "/worker/credentials/confirm")
    guard matches, !failed else { return false }
    failed = true
    return true
  }

  func persist(_ next: ExecutionWorkerManifest, point: String) throws {
    if next.credentials.successor != nil {
      manifest = next
      pendingSaves += 1
      if point == "pendingSave", !failed { failed = true; throw WorkerProtocolError(.unavailable, message: "interrupted persistence") }
    } else {
      if point == "finalSave", !failed { failed = true; throw WorkerProtocolError(.unavailable, message: "interrupted persistence") }
      manifest = next
      finalSaves += 1
    }
  }
}

@Test(arguments: ["pendingSave", "stageReply", "confirmReply", "finalSave", "none"])
func workerCredentialRecoverySurvivesEveryPersistenceAndAcknowledgementBoundary(point: String) async throws {
  let original = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: 123, birth: "test-process-birth-identity", credentials: .init(current: String(repeating: "a", count: 72)))
  let disk = RotationDisk(manifest: original)
  let childCredentials = try WorkerCredentials(token: original.credentials.current)
  let hello = WorkerHello(capabilities: WorkerHello.baseline.union(["worker.credential-rotation.v1", "owner.continuity.v1"]), release: "worker").retainingReplies(UUID())
  let endpoint = WorkerEndpoint(credentials: childCredentials, hello: hello, invoke: { $0.payload }, upload: { _, _ in }, download: { _ in .empty })
  let fetch = FetchClient { request in
    #expect(await disk.networkAllowed)
    let response = try await endpoint.handler(request)
    if await disk.loseResponse(point: point, path: request.url.path) { throw WorkerProtocolError(.unavailable, message: "lost acknowledgement") }
    return response
  }
  let persist: @Sendable (ExecutionWorkerManifest) async throws -> Void = { manifest in
    try await disk.persist(manifest, point: point)
  }
  let connect: @Sendable (WorkerCredentials) throws -> WorkerClient = { credentials in
    try WorkerClient(socket: "/private/worker.sock", credentials: credentials, control: fetch, bytes: fetch)
  }
  let prepare: @Sendable (ExecutionWorkerManifest) async throws -> ExecutionWorkerCredentialRotation.PreparedCredentials = { manifest in
    try await ExecutionWorkerCredentialRotation.prepare(manifest: manifest, hello: hello, persist: persist, connect: connect, processBirth: { _ in original.birth })
  }
  if point != "none" {
    await #expect(throws: WorkerProtocolError.self) { try await prepare(original) }
    #expect((await disk.manifest).credentials.successor != nil)
  }
  let admitted = try await prepare(await disk.manifest)
  #expect(await disk.pendingSaves == 1)
  #expect(await disk.finalSaves == 1)
  #expect(admitted.manifest.credentials.successor == nil)
  #expect(admitted.manifest.credentials.current != original.credentials.current)
  #expect(admitted.manifest.credentials.current == (await childCredentials.outgoingToken))
  #expect(await admitted.client.retainsReplies)
  #expect(try await admitted.client.call(.init(operation: "echo", payload: "same journal")) == "same journal")
  let old = try WorkerClient(socket: "/private/worker.sock", token: original.credentials.current, control: fetch, bytes: fetch)
  await #expect(throws: WorkerProtocolError.self) { try await old.negotiate(hello) }
}

@Test func workerCredentialRecoveryRefusesPIDChangeAfterAuthenticatedHandshake() async throws {
  let original = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: 123, birth: "test-process-birth-identity", credentials: .init(current: String(repeating: "a", count: 72)))
  let disk = Mutex(original)
  let child = try WorkerCredentials(token: original.credentials.current)
  let hello = WorkerHello(capabilities: WorkerHello.baseline.union(["worker.credential-rotation.v1", "owner.continuity.v1"]), release: "worker").retainingReplies(UUID())
  let endpoint = WorkerEndpoint(credentials: child, hello: hello, invoke: { _ in .null }, upload: { _, _ in }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let probes = Mutex(0)
  await #expect(throws: WorkerProtocolError.self) {
    try await ExecutionWorkerCredentialRotation.prepare(manifest: original, hello: hello, persist: { manifest in disk.withLock { $0 = manifest } }, connect: { credentials in
      try WorkerClient(socket: "/private/worker.sock", credentials: credentials, control: fetch, bytes: fetch)
    }, processBirth: { _ in
      probes.withLock { count in count += 1; return count == 1 ? original.birth : "reused-pid-birth-identity" }
    })
  }
  #expect(probes.withLock { $0 } == 2)
  #expect(disk.withLock { $0.credentials.successor != nil })
}

@Test func workerCredentialRecoveryCannotSwitchJournalsOrReplayEffects() async throws {
  let original = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: 123, birth: "test-process-birth-identity", credentials: .init(current: String(repeating: "a", count: 72)))
  let disk = Mutex(original)
  let child = try WorkerCredentials(token: original.credentials.current)
  let hello = WorkerHello(capabilities: WorkerHello.baseline.union(["worker.credential-rotation.v1", "owner.continuity.v1"]), release: "worker").retainingReplies(UUID())
  let endpoint = WorkerEndpoint(credentials: child, hello: hello, invoke: { _ in Issue.record("No execution effects belong in credential recovery"); return .null }, upload: { _, _ in }, download: { _ in .empty })
  let helloCount = Mutex(0)
  let fetch = FetchClient { request in
    let response = try await endpoint.handler(request)
    if request.url.path == "/worker/hello", response.status.code == 200 {
      let changed = helloCount.withLock { $0 += 1; return $0 > 1 }
      if changed { return try .json(hello.retainingReplies(UUID())) }
    }
    return response
  }
  await #expect(throws: WorkerProtocolError(.unknownOutcome, message: "Owner receipt journal changed; reconcile pending effects before reconnecting")) {
    try await ExecutionWorkerCredentialRotation.prepare(manifest: original, hello: hello, persist: { manifest in disk.withLock { $0 = manifest } }, connect: { credentials in
      try WorkerClient(socket: "/private/worker.sock", credentials: credentials, control: fetch, bytes: fetch)
    }, processBirth: { _ in original.birth })
  }
  #expect(disk.withLock { $0.credentials.successor != nil })
}
