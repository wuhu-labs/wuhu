#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import Synchronization
import Testing
@testable import WorkerProtocol

private let rotationHello = WorkerHello(capabilities: WorkerHello.baseline.union(["worker.credential-rotation.v1"]), release: "rotation")

private func rotationEndpoint(_ credentials: WorkerCredentials) -> WorkerEndpoint {
  WorkerEndpoint(credentials: credentials, hello: rotationHello, invoke: { $0.payload }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
}

@Test func successorConfirmationRevokesOldCredentialInBothDirections() async throws {
  let parentCredentials = try WorkerCredentials(token: "old")
  let childCredentials = try WorkerCredentials(token: "old")
  let parentEndpoint = rotationEndpoint(parentCredentials)
  let childEndpoint = rotationEndpoint(childCredentials)
  let parentFetch = FetchClient { try await parentEndpoint.handler($0) }
  let childFetch = FetchClient { try await childEndpoint.handler($0) }
  let parent = try WorkerClient(socket: "/private/child.sock", credentials: parentCredentials, control: childFetch, bytes: childFetch)
  let child = try WorkerClient(socket: "/private/parent.sock", credentials: childCredentials, control: parentFetch, bytes: parentFetch)
  _ = try await parent.negotiate(rotationHello)
  _ = try await child.negotiate(rotationHello)
  try await parentCredentials.stage(successor: "successor")
  try await parent.stagePeerCredential(successor: "successor", authenticatingWith: "old")
  #expect(try await child.call(.init(operation: "echo", payload: "during staging")) == "during staging")
  try await parent.confirmPeerCredential(authenticatingWith: "successor")
  try await parentCredentials.confirm(successor: "successor")
  for fetch in [parentFetch, childFetch] {
    let old = try WorkerClient(socket: "/private/test.sock", token: "old", control: fetch, bytes: fetch)
    await #expect(throws: WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted")) { try await old.negotiate(rotationHello) }
  }
  #expect(try await child.call(.init(operation: "echo", payload: "after confirmation")) == "after confirmation")
  #expect(try await parent.call(.init(operation: "echo", payload: "after confirmation")) == "after confirmation")
}

@Test func unconfirmedRotationExpiresWithoutExtendingOnRetry() async throws {
  let instant = Mutex(ContinuousClock.now)
  let credentials = try WorkerCredentials(token: "old", now: { instant.withLock { $0 } })
  let endpoint = rotationEndpoint(credentials)
  let fetch = FetchClient { try await endpoint.handler($0) }
  let old = try WorkerClient(socket: "/private/test.sock", token: "old", control: fetch, bytes: fetch)
  _ = try await old.negotiate(rotationHello)
  try await old.stagePeerCredential(successor: "successor", authenticatingWith: "old")
  instant.withLock { $0 = $0.advanced(by: .seconds(9)) }
  try await old.stagePeerCredential(successor: "successor", authenticatingWith: "old")
  #expect(try await old.call(.init(operation: "echo", payload: true)) == true)
  instant.withLock { $0 = $0.advanced(by: .seconds(1)) }
  await #expect(throws: WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted")) { try await old.call(.init(operation: "echo")) }
  let successor = try WorkerClient(socket: "/private/test.sock", token: "successor", control: fetch, bytes: fetch)
  _ = try await successor.negotiate(rotationHello)
  try await successor.confirmPeerCredential(authenticatingWith: "successor")
  #expect(try await successor.call(.init(operation: "echo", payload: "recovered")) == "recovered")
}

@Test func lostStageAndConfirmationRepliesAreRecoverableWithSuccessorOnly() async throws {
  let instant = Mutex(ContinuousClock.now)
  let credentials = try WorkerCredentials(token: "old", now: { instant.withLock { $0 } })
  let endpoint = rotationEndpoint(credentials)
  let lostReplies = Mutex(Set(["/worker/credentials/stage", "/worker/credentials/confirm"]))
  let fetch = FetchClient { request in
    let response = try await endpoint.handler(request)
    if lostReplies.withLock({ $0.remove(request.url.path) != nil }) { throw WorkerProtocolError(.unavailable, message: "lost reply") }
    return response
  }
  let client = try WorkerClient(socket: "/private/test.sock", token: "old", control: fetch, bytes: fetch)
  _ = try await client.negotiate(rotationHello)
  await #expect(throws: WorkerProtocolError.self) { try await client.stagePeerCredential(successor: "successor", authenticatingWith: "old") }
  instant.withLock { $0 = $0.advanced(by: .seconds(10)) }
  let recovered = try WorkerClient(socket: "/private/test.sock", token: "successor", control: fetch, bytes: fetch)
  _ = try await recovered.negotiate(rotationHello)
  try await recovered.stagePeerCredential(successor: "successor", authenticatingWith: "successor")
  await #expect(throws: WorkerProtocolError.self) { try await recovered.confirmPeerCredential(authenticatingWith: "successor") }
  try await recovered.confirmPeerCredential(authenticatingWith: "successor")
  #expect(try await recovered.call(.init(operation: "echo", payload: "same child")) == "same child")
  await #expect(throws: WorkerProtocolError.self) { try await client.negotiate(rotationHello) }
}

@Test func rotationRequiresNegotiationAndSuccessorProof() async throws {
  let credentials = try WorkerCredentials(token: "old")
  let endpoint = rotationEndpoint(credentials)
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "old", control: fetch, bytes: fetch)
  _ = try await client.negotiate(rotationHello)
  try await client.stagePeerCredential(successor: "successor", authenticatingWith: "old")
  await #expect(throws: WorkerProtocolError.self) { try await client.confirmPeerCredential(authenticatingWith: "old") }
  await #expect(throws: WorkerProtocolError.self) { try await client.stagePeerCredential(successor: "different", authenticatingWith: "old") }
  try await client.confirmPeerCredential(authenticatingWith: "successor")
  let legacyEndpoint = try WorkerEndpoint(token: "old", hello: .init(release: "legacy"), invoke: { _ in .null }, upload: { _, _ in }, download: { _ in .empty })
  let legacyFetch = FetchClient { try await legacyEndpoint.handler($0) }
  let legacy = try WorkerClient(socket: "/private/test.sock", token: "old", control: legacyFetch, bytes: legacyFetch)
  _ = try await legacy.negotiate(rotationHello)
  await #expect(throws: WorkerProtocolError.self) { try await legacy.stagePeerCredential(successor: "successor", authenticatingWith: "old") }
}

@Test func credentialChangedBeforeAdmissionIsRetryableWithoutReplayingBody() async throws {
  let credentials = try WorkerCredentials(token: "old")
  let endpointCredentials = try WorkerCredentials(token: "old")
  let endpoint = rotationEndpoint(endpointCredentials)
  let dispatches = Mutex(0)
  let fetch = FetchClient { request in
    if request.url.path == "/worker/call" {
      try await credentials.stage(successor: "successor")
      try await endpointCredentials.stage(successor: "successor")
      try await endpointCredentials.confirm(successor: "successor")
      dispatches.withLock { $0 += 1 }
    }
    return try await endpoint.handler(request)
  }
  let client = try WorkerClient(socket: "/private/test.sock", credentials: credentials, control: fetch, bytes: fetch)
  _ = try await client.negotiate(rotationHello)
  await #expect(throws: WorkerProtocolError(.unavailable, message: "Worker credential changed before admission; reconnect required")) {
    try await client.call(.init(operation: "echo", payload: "not admitted"))
  }
  #expect(dispatches.withLock { $0 } == 1)
  #expect(try await client.call(.init(operation: "echo", payload: "fresh admission")) == "fresh admission")
}

private struct RevokingRequestBody: AsyncSequence, Sendable {
  typealias Element = Bytes
  let credentials: WorkerCredentials
  let bytes: Bytes
  struct AsyncIterator: AsyncIteratorProtocol {
    let credentials: WorkerCredentials
    var bytes: Bytes?
    mutating func next() async throws -> Bytes? {
      guard let result = bytes else { return nil }
      bytes = nil
      try await credentials.stage(successor: "successor")
      try await credentials.confirm(successor: "successor")
      return result
    }
  }

  func makeAsyncIterator() -> AsyncIterator { .init(credentials: credentials, bytes: bytes) }
}

@Test func slowOldCredentialBodyCannotAdmitAnEffectAfterRevocation() async throws {
  let credentials = try WorkerCredentials(token: "old")
  let effects = Mutex(0)
  let endpoint = WorkerEndpoint(credentials: credentials, hello: rotationHello, invoke: { _ in effects.withLock { $0 += 1 }; return .null }, upload: { _, _ in }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "old", control: fetch, bytes: fetch)
  _ = try await client.negotiate(rotationHello)
  let body = RevokingRequestBody(credentials: credentials, bytes: try JSONEncoder().encode(WorkerCall(operation: "effect")))
  let request = Request(url: URL(string: "http://owner/worker/call")!, method: .post, headers: RequestHeaders(values: ["Authorization": "Bearer old"]), body: .stream(body))
  let response = try await endpoint.handler(request)
  #expect(try await response.json(WorkerProtocolError.self).code == .unauthorized)
  #expect(effects.withLock { $0 } == 0)
}
