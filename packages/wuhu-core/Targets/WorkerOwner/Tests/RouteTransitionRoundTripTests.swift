#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Credentials
import ExecutionOwner
import SessionDomain
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol
import WuhuAI

@Suite struct RouteTransitionRoundTripTests {
  @Test(arguments: [false, true])
  func failureEpisodesAndAtomicTransitionsRemainParentOwned(compaction: Bool) async throws {
    let space = try Space.inMemory()
    let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")
    let old = SessionModelRoute(group: "work", member: "primary", specifier: model, bindingFingerprint: "fixture", epoch: "old", reason: .create, placedAt: Date(), evidence: [])
    let id = try await space.sessions.createSession(group: .shared, title: "transition", kind: .agent, createdBy: "owner", executor: .modelGroup(id: "work", effort: "none"), modelRoute: old)
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      let failure = ModelRouteFailure(reason: .quota, firstFailureAt: Date(), deadline: Date().addingTimeInterval(1800), retryAt: nil)
      try await remote.updateModelRouteFailure(id, expectedEpoch: old.epoch, failure: failure)
      #expect(try await space.sessions.modelRoute(id)?.failure == failure)
      await #expect(throws: PortableHandoffConflict.routeChanged) { try await remote.updateModelRouteFailure(id, expectedEpoch: "obsolete", failure: nil) }
      let hydration = try await remote.hydrate(id)
      let source = switch hydration.transcript { case let .kernel(value): value }
      var next = old
      next.member = "secondary"; next.epoch = "new"; next.reason = .compaction
      let binding = ReplayBinding(identity: "scope-b", epoch: next.epoch)
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "folded", snapshot: .init(), replayBinding: binding)
      let portable: Transcript
      if compaction { portable = source.compacted(head: head, kept: nil) }
      else { portable = try source.portableHandoff(binding: binding, budget: .init(maxInput: 100_000, maxOutput: 1000)) }
      let transition = ModelRouteTransition(expectedEpoch: old.epoch, route: next, transcript: portable)
      let result: Transcript
      if compaction {
        result = try await remote.writeCompaction(id, closing: nil, head: head, kept: nil, completingCompactRequest: nil, transition: transition)
      } else {
        result = try await remote.writePortableHandoff(id, expectedGeneration: hydration.generation, source: source, transcript: portable, transition: transition)
      }
      #expect(result.replayBinding == binding)
      #expect(try await space.sessions.modelRoute(id) == next)
      #expect(try await space.sessions.modelRouteHistory(id) == [old, next])
      #expect(try await space.sessions.hydrate(id).generation == hydration.generation + 1)
    }
  }

  @Test(arguments: [false, true])
  func olderABI1ParentRefusesTransitionBeforeAnyPartialEffect(compaction: Bool) async throws {
    let space = try Space.inMemory()
    let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")
    let old = SessionModelRoute(group: "work", member: "primary", specifier: model, bindingFingerprint: "fixture", epoch: "old", reason: .create, placedAt: Date(), evidence: [])
    let id = try await space.sessions.createSession(group: .shared, title: "mixed version", kind: .agent, createdBy: "owner", executor: .modelGroup(id: "work", effort: "none"), modelRoute: old)
    let current = ExecutionWorkerBootstrap.hello(release: "current")
    let older = WorkerHello(capabilities: current.capabilities.subtracting([ExecutionWorkerBootstrap.routeTransitionsCapability]), required: current.required, release: "older-abi1")
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), hello: older) { _, remote in
      let before = try await space.sessions.hydrate(id)
      let source = switch before.transcript { case let .kernel(value): value }
      var next = old
      next.epoch = "new"; next.member = "secondary"
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "folded", snapshot: .init())
      let transition = ModelRouteTransition(expectedEpoch: old.epoch, route: next, transcript: source.compacted(head: head, kept: nil))
      let expected = WorkerProtocolError(.missingCapability, message: "Missing execution capability: " + ExecutionWorkerBootstrap.routeTransitionsCapability)
      await #expect(throws: expected) {
        if compaction {
          _ = try await remote.writeCompaction(id, closing: nil, head: head, kept: nil, completingCompactRequest: nil, transition: transition)
        } else {
          _ = try await remote.writePortableHandoff(id, expectedGeneration: before.generation, source: source, transcript: transition.transcript, transition: transition)
        }
      }
      await #expect(throws: expected) { try await remote.updateModelRouteFailure(id, expectedEpoch: old.epoch, failure: nil) }
      #expect(try await space.sessions.hydrate(id) == before)
      #expect(try await space.sessions.modelRoute(id) == old)
      #expect(try await space.sessions.modelRouteHistory(id) == [old])
    }
  }

  @Test func credentialLoginRefusalKeepsTypedRefreshClassification() async throws {
    let space = try Space.inMemory()
    let expected = ChatGPTAuthError.loginRequired(detail: "refresh returned 401")
    let owner = InProcessExecutionOwnerClient(space: space, credentials: .bound { _ in throw expected })
    _ = try await withOwnerRPC(owner: owner) { _, remote in
      await #expect(throws: expected) { try await remote.providerCredentialBinding("offline") }
    }
  }

  @Test(arguments: [InferenceError.oidcSigningFailed(provider: "offline"), .credentialRefreshRefused(provider: "offline"), .authenticationRefused(code: "account_banned"), .upstreamUnavailable(code: "server_overloaded"), .streamCut])
  func typedRoutingRefusalsRoundTrip(_ error: InferenceError) throws {
    #expect(try InferenceFailureSnapshot(error).error() == error)
  }
}
