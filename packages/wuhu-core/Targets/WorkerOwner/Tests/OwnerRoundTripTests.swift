#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialResolver
import protocol ExecutionOwner.ExecutionOwnerClient
import struct ExecutionOwner.InProcessExecutionOwnerClient
import Fetch
import InferenceKit
import SessionDomain
import SessionTools
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol

func withOwnerRPC<Value>(owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, hello: WorkerHello = ExecutionWorkerBootstrap.hello(release: "parent-newer"), body: (WorkerClient, RemoteExecutionOwner) async throws -> Value) async throws -> Value {
  let parent = ParentExecutionEndpoint(owner: owner, runtime: runtime)
  let endpoint = try OwnerByteEndpoint(invoke: parent.invoke, upload: parent.upload, download: parent.stream, acknowledged: parent.acknowledge).endpoint(token: "fixture-only", hello: hello)
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture-only", control: fetch, bytes: fetch)
  _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker-newer"))
  do {
    let value = try await body(client, RemoteExecutionOwner(client: client, tracesAttempts: owner.tracesAttempts, machines: true))
    await parent.shutdown()
    return value
  } catch {
    await parent.shutdown()
    throw error
  }
}

@Suite(.timeLimit(.minutes(1))) struct OwnerRoundTripTests {
  let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")

  @Test func sessionSnapshotsAndQueueWritesAreParentOwned() async throws {
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "remote", kind: .agent, createdBy: "owner", model: model)
    let local = InProcessExecutionOwnerClient(space: space)
    try await withOwnerRPC(owner: local) { _, remote in
      #expect(try await remote.record(id) == space.sessions.record(id))
      #expect(try await remote.hydrate(id) == space.sessions.hydrate(id))
      let input = QueueInput.notification(.init(id: UUID(), timestamp: .init(timeIntervalSince1970: 5), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "hello")))
      let tail = try await remote.enqueue(id, input: input)
      #expect(tail == 1)
      let drained = try await remote.drainQueue(id)
      #expect(drained.queueTail == tail)
      #expect(drained.items.count == 1)
      #expect(try await remote.queueHead(id) == tail)
      try await remote.markInterrupted(id)
      #expect(try await space.sessions.record(id).hold == .interrupted)
      try await remote.markResumed(id)
      #expect(try await space.sessions.record(id).hold == .normal)
      try await remote.markErrored(id, message: "offline failure")
      #expect(try await space.sessions.record(id).errorMessage == "offline failure")
      let restarted = try await remote.restart(id, executor: .kernel(model), note: "again", modelRoute: nil)
      #expect(restarted == .init(generation: 1, executor: .kernel(model)))
      let expiry = try await remote.archive(id, grace: .seconds(13))
      #expect(try await remote.record(id).lifecycle == space.sessions.record(id).lifecycle)
      #expect(expiry > Date(timeIntervalSince1970: 0))
      try await remote.unarchive(id)
      #expect(try await space.sessions.record(id).lifecycle == .live)
      #expect(try await remote.scopeContext(id, toolCallID: .init("absent")) == nil)
      #expect(try await remote.pendingCommand(id) == nil)
      #expect(try await remote.modelRoute(id) == nil)
      let subscriptions = try await remote.registeredSubscriptions(id)
      #expect(subscriptions.ids.isEmpty)
      #expect(subscriptions.handlers.isEmpty)
    }
  }

  @Test func unknownSessionRetainsItsTypedStoreError() async throws {
    let space = try Space.inMemory()
    _ = try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      await #expect(throws: SessionStoreError.unknownSession("absent")) { try await remote.record(.init(rawValue: "absent")) }
    }
  }

  @Test func largePromptAndTranscriptUseBytesNotControlFrames() async throws {
    let space = try Space.inMemory()
    let large = String(repeating: "x", count: 2 << 20)
    _ = try await space.fs(.shared).write("/AGENTS.md", Data(large.utf8), ifMatch: nil)
    let id = try await space.sessions.createSession(group: .shared, title: "large", kind: .agent, createdBy: "owner", model: model)
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      #expect(try await remote.promptHome(id).groupLayer.sections.first?.text == large)
      let input = QueueInput.notification(.init(id: UUID(), timestamp: .init(timeIntervalSince1970: 5), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: large)))
      _ = try await remote.enqueue(id, input: input)
      let drained = try await remote.drainQueue(id)
      var transcript = Transcript()
      for item in drained.items { transcript.append(item) }
      let item = TranscriptItem.notification(.init(id: UUID(), timestamp: .init(timeIntervalSince1970: 6), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: large)))
      transcript.append(item)
      try await remote.append(id, items: [item], transcript: transcript, completingCompactRequest: nil)
      #expect(try await remote.hydrate(id).transcript == space.sessions.hydrate(id).transcript)
    }
  }

  @Test func opaqueCompactClaimsAreSessionBoundAndAtomicallyRejectReplacement() async throws {
    let space = try Space.inMemory()
    let first = try await space.sessions.createSession(group: .shared, title: "first", kind: .agent, createdBy: "owner", model: model)
    let second = try await space.sessions.createSession(group: .shared, title: "second", kind: .agent, createdBy: "owner", model: model)
    try await space.sessions.requestCommand(first, .compact(instructions: "keep old"))
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      let claim = try #require(await remote.claimCompactRequest(first, generation: 0))
      let completion = TranscriptItem.notification(.init(id: UUID(), timestamp: Date(timeIntervalSince1970: 6), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "completed")))
      var claimedTranscript = claim.transcript
      claimedTranscript.append(completion)
      #expect(claim.opaqueHandle != nil)
      let again = try #require(await remote.claimCompactRequest(first, generation: 0))
      #expect(again.opaqueHandle == claim.opaqueHandle)
      do {
        try await remote.append(second, items: [completion], transcript: claimedTranscript, completingCompactRequest: claim)
        Issue.record("A foreign claim was accepted")
      } catch let error as WorkerProtocolError { #expect(error.code == .invalidMessage) }
      try await space.sessions.requestCommand(first, .compact(instructions: "keep new"))
      await #expect(throws: StaleCompactClaim.self) {
        try await remote.append(first, items: [completion], transcript: claimedTranscript, completingCompactRequest: claim)
      }
      #expect(try await space.sessions.pendingCommand(first) == .compact(instructions: "keep new"))
      let current = try #require(await remote.claimCompactRequest(first, generation: 0))
      var currentTranscript = current.transcript
      currentTranscript.append(completion)
      try await remote.append(first, items: [completion], transcript: currentTranscript, completingCompactRequest: current)
      #expect(try await space.sessions.pendingCommand(first) == nil)
      do {
        var currentTranscript = current.transcript
        currentTranscript.append(completion)
        try await remote.append(first, items: [completion], transcript: currentTranscript, completingCompactRequest: current)
        Issue.record("A consumed claim was accepted")
      } catch let error as WorkerProtocolError { #expect(error.code == .invalidMessage) }
    }
  }

  @Test func credentialsBindingsAndModelDocumentsCrossTheFacet() async throws {
    let space = try Space.inMemory()
    _ = try await space.fs(.shared).write("/models.json", Data("{}".utf8), ifMatch: nil)
    let credentials = CredentialResolver.bound { _ in .init(credential: .chatGPT(accessToken: "fixture", accountID: "account"), identityEpoch: "epoch", permitsOpaqueReplay: false) }
    let owner = InProcessExecutionOwnerClient(space: space, credentials: credentials)
    try await withOwnerRPC(owner: owner) { _, remote in
      #expect(try await remote.providerCredential("offline") == .chatGPT(accessToken: "fixture", accountID: "account"))
      let binding = try #require(await remote.providerCredentialBinding("offline"))
      #expect(binding.identityEpoch == "epoch")
      #expect(!binding.permitsOpaqueReplay)
      #expect(try await remote.modelDocument() == owner.modelDocument())
      #expect(try await remote.modelGroupDocument() == nil)
    }
  }
}
