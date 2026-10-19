import Credentials
import Dependencies
import ExecutionOwner
import Fetch
import Foundation
import InferenceKit
import JSONValue
import LoopCore
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

@Suite struct GroupSwitchingTests {
  func setup(seconds: Int = 1800, policy: ModelsDocument.Policy? = nil, model: String = "test-model") async throws -> (SessionHarness, Hub, ProviderCatalog, SessionID) {
    let harness = try await SessionHarness(credentials: .bound { provider in
      .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
    })
    try await ModelGroupRouteTests().install(harness, model: model)
    let fs = await harness.space.fs(.shared)
    let (entry, data) = try await fs.read(ModelsDocument.groupPath)
    var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
    groups["work"]!.policy = policy ?? .quotaAware(holdDownSeconds: seconds)
    _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
    let owner = Hub(space: harness.space, credentials: harness.credentials)
    let catalog = try await groupCatalog(owner: owner)()
    let created = try await harness.call("/v1/session", .object(["title": "Switch", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
    return (harness, owner, catalog, SessionID(created.id))
  }

  @Test func durableEpisodeKeepsFirstDeadlineAndSuccessClearsIt() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, owner, catalog, id) = try await setup()
        let pin = try #require(await owner.modelRoute(id))
        let first = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: Date(timeIntervalSince1970: 30000)), session: id, owner: owner, catalog: catalog))
        #expect(first.deadline == Date(timeIntervalSince1970: 11800))
        now.withLock { $0 = Date(timeIntervalSince1970: 11000) }
        let repeated = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: Date(timeIntervalSince1970: 30000)), session: id, owner: owner, catalog: catalog))
        #expect(repeated.deadline == first.deadline)
        #expect(repeated.firstFailureAt == first.firstFailureAt)
        let rehydratedOwner = Hub(space: harness.space, credentials: harness.credentials)
        let held = try #require(await rehydratedOwner.modelRoute(id))
        #expect(held.failure == repeated)
        await #expect(throws: ModelRouteWaiting.self) { try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage) }
        now.withLock { $0 = Date(timeIntervalSince1970: 11800) }
        do {
          try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage)
          Issue.record("deadline must require portable boundary")
        } catch let boundary as ReplayBoundaryRequired {
          #expect(boundary.route?.member == "b")
          #expect(boundary.route?.decisionReason == "lastResort:quota")
          #expect(boundary.expectedEpoch == pin.epoch)
        }
        try await owner.append(id, .modelRouteFailureUpdated(expectedEpoch: held.epoch, failure: nil)).value(Void.self)
        #expect(try await owner.modelRoute(id)?.failure == nil)
        #expect(try await harness.store.modelRouteHistory(id) == [pin])
      }
    }
  }

  @Test func nearResetWaitsAndAllowsSourceRetryEvenAfterRestartPastDeadline() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, owner, catalog, id) = try await setup()
        _ = try await recordRouteFailure(InferenceError.rateLimited(retryAt: Date(timeIntervalSince1970: 10600)), session: id, owner: owner, catalog: catalog)
        let held = try #require(await owner.modelRoute(id))
        do { try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage) }
        catch let wait as ModelRouteWaiting { #expect(wait.retryAt == Date(timeIntervalSince1970: 10600)) }
        now.withLock { $0 = Date(timeIntervalSince1970: 12000) }
        try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage)
        #expect(try await owner.modelRoute(id)?.epoch == held.epoch)
        let repeated = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: Date(timeIntervalSince1970: 10600)), session: id, owner: owner, catalog: catalog))
        #expect(repeated.retryAt == nil)
        #expect(repeated.deadline == held.failure?.deadline)
        let refusing = try #require(await owner.modelRoute(id))
        await #expect(throws: ReplayBoundaryRequired.self) { try await routeWaitOrSwitch(refusing, session: id, catalog: catalog, usage: harness.runtime.usage) }
      }
    }
  }

  @Test func onlyActualTypedRefusalsOrThirdOutageQualifyAndSelectNeverSwitches() async throws {
    try await withSessionDeps {
      let (_, owner, catalog, id) = try await setup()
      for error in [InferenceError.invalidInput(status: 403, body: "model permission"), .contextTooLong, .cancelled, .malformedModelMessage(message: "bad", reason: nil), .transient(status: nil, body: "parser"), .other(status: nil, body: "config"), .transport(.connectionClosed), .transport(.readTimeout), .transport(.idleTimeout)] {
        #expect(try await recordRouteFailure(error, session: id, owner: owner, catalog: catalog) == nil)
      }
      #expect(try await recordRouteFailure(CatalogError.unknownModel(provider: "testing", model: "typo"), session: id, owner: owner, catalog: catalog) == nil)
      let outages: [InferenceError] = [.transient(status: 503, body: nil), .upstreamUnavailable(code: "overloaded_error"), .transient(status: 529, body: nil)]
      var deadline: Date?
      for (index, error) in outages.enumerated() {
        let count = index + 1
        let failure = try #require(await recordRouteFailure(error, session: id, owner: owner, catalog: catalog))
        if let deadline { #expect(failure.deadline == deadline) } else { deadline = failure.deadline }
        #expect(failure.consecutiveFailures == count)
        #expect(failure.refusing == (count == 3))
      }
      let (_, selectOwner, selectCatalog, selectID) = try await setup(policy: .select(member: "a"))
      #expect(try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: selectID, owner: selectOwner, catalog: selectCatalog) == nil)
    }
  }

  @Test func ordinaryCompactionUsesHeadroomPreservesSummaryAndAvoidsSamePinChurn() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup()
      let old = try #require(await owner.modelRoute(id))
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: String(repeating: "important summary ", count: 50), snapshot: .init(preReads: ["/task.md"]), runningWork: ["exec.running"])
      let compacted = try await harness.store.transcript(id).compacted(head: head, kept: nil)
      let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
      #expect(try await prepare(id, compacted, nil) == nil)
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: Date().timeIntervalSince1970 + 18000)], at: Date())
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: Date().timeIntervalSince1970 + 18000)], at: Date())
      let transition = try #require(await prepare(id, compacted, nil))
      #expect(transition.route.member == "b")
      #expect(transition.route.reason == .compaction)
      guard case let .generationHead(portableHead) = transition.transcript.items[0] else { Issue.record("missing head"); return }
      #expect(portableHead.summary == head.summary)
      #expect(portableHead.runningWork == head.runningWork)
      #expect(portableHead.snapshot.preReads == head.snapshot.preReads)
      _ = try await owner.append(id, .compacted(closing: nil, head: head, kept: nil, completing: nil, transition: transition)).value(Transcript.self)
      #expect(try await owner.modelRoute(id) == transition.route)
      #expect(try await harness.store.modelRouteHistory(id) == [old, transition.route])
      #expect(try await harness.store.transcript(id).replayBinding?.epoch == transition.route.epoch)
      #expect(try await prepare(id, transition.transcript, nil) == nil)
    }
  }

  @Test func exhaustedAlternativesWaitAndFailureSuppressesWarming() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup(seconds: 0)
      _ = try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, owner: owner, catalog: catalog)
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 100, resetsAt: Date().timeIntervalSince1970 + 18000)], at: Date())
      let held = try #require(await owner.modelRoute(id))
      await #expect(throws: ModelRouteWaiting.self) { try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage) }
      #expect(try await CacheWarmer(space: harness.space, usage: harness.runtime.usage).allows(id) == false)
      #expect(try await owner.modelRoute(id)?.member == "a")
    }
  }
}

extension GroupSwitchingTests {
  @Test func actualRuntimeRefusalCompactsBeforeDestinationAndNeverAutomaticallyReturns() async throws {
    try await withSessionDeps {
      let requests = Mutex<[(String, String)]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.text() ?? ""
          let round = requests.withLock { $0.append((request.headers.sensitiveValues["authorization"] ?? "", body)); return $0.count }
          if round == 2 {
            var headers = Headers()
            headers[.retryAfter] = "18000"
            return Response(status: .tooManyRequests, headers: headers, body: .string("quota"))
          }
          let events: String
          if round == 1 {
            events = [
              "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"native-account-a\",\"summary\":[],\"encrypted_content\":\"signature-account-a\"}}",
              "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"native-account-a\",\"summary\":[],\"encrypted_content\":\"signature-account-a\"}}",
              "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp-a\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}",
            ].map { "data: \($0)\n\n" }.joined()
          } else {
            events = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-b\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n\n"
          }
          return Response(status: .ok, body: .bytes(Data(events.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) })
        try await ModelGroupRouteTests().install(harness)
        let fs = await harness.space.fs(.shared)
        let (entry, data) = try await fs.read(ModelsDocument.groupPath)
        var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
        groups["work"]!.policy = .quotaAware(holdDownSeconds: 0)
        _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
        let created = try await harness.call("/v1/session", .object(["title": "Runtime switch", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        let original = try #require(await harness.store.modelRoute(id))
        try await harness.running {
          try await harness.deliver("first request", to: id)
          try await until("source success") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 1 }
          try await harness.deliver("outstanding second request", to: id)
          try await until("destination success") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 3 }
          let next = try #require(await harness.store.modelRoute(id))
          #expect(next.member == "b")
          #expect(next.switchCause == .quota)
          #expect(next.failure == nil)
          #expect(next.epoch != original.epoch)
          #expect(try await harness.store.generationState(id).generation == 1)
          #expect(try await harness.store.modelRouteHistory(id) == [original, next])
          let emitted = requests.withLock { $0 }
          #expect(emitted[0].0 == "Bearer key-testing")
          #expect(emitted[1].0 == "Bearer key-testing")
          #expect(emitted[2].0 == "Bearer key-alternate")
          #expect(!emitted[2].1.contains("signature-account-a"))
          #expect(!emitted[2].1.contains("native-account-a"))
          #expect(emitted[2].1.contains("outstanding second request"))
          #expect(emitted[2].1.contains("lastResort:quota"))
          try await harness.deliver("third request", to: id)
          try await until("replacement remains pinned") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 4 }
          #expect(try await harness.store.modelRoute(id) == next)
          #expect(requests.withLock { $0.last?.0 } == "Bearer key-alternate")
        }
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test func typedRefreshRefusalOnlyAffectsHeldProviderAndWarmingFollowsReplacement() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup(seconds: 0)
      let fs = await harness.space.fs(.shared)
      let (entry, data) = try await fs.read(ModelsDocument.spacePath)
      var document = try ModelsDocument(json: data)
      for provider in ["testing", "alternate"] { document.providers[provider]!.models["test-model"]!.cacheWarming = .init(floorTokens: 1) }
      _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: entry)
      let other = try await harness.call("/v1/session", .object(["title": "Other held account", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let otherID = SessionID(other.id)
      for session in [id, otherID] { try await harness.store.appendAssistant(session, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 0, totalTokens: 10))) }
      let warmer = CacheWarmer(space: harness.space, usage: harness.runtime.usage)
      #expect(try await warmer.allows(id))
      #expect(try await warmer.allows(otherID))
      #expect(try await recordRouteFailure(InferenceError.credentialRefreshRefused(provider: "alternate"), session: id, owner: owner, catalog: catalog, inferenceStarted: false) == nil)
      let failure = try #require(await recordRouteFailure(InferenceError.credentialRefreshRefused(provider: "testing"), session: id, owner: owner, catalog: catalog, inferenceStarted: false))
      #expect(failure.source == .credentialRefresh)
      #expect(failure.code == "loginRequired")
      #expect(try await warmer.allows(id) == false)
      #expect(try await warmer.allows(otherID) == false)
      let held = try #require(await owner.modelRoute(id))
      do { try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage); Issue.record("missing route boundary") }
      catch let boundary as ReplayBoundaryRequired {
        let hydration = try await owner.hydrate(id)
        guard case let .kernel(source) = hydration.transcript else { Issue.record("missing kernel transcript"); return }
        let portable = try source.portableHandoff(binding: boundary.binding, budget: boundary.budget, runningWork: [])
        let next = try #require(boundary.route)
        _ = try await owner.append(id, .portableHandoff(expectedGeneration: hydration.generation, source: source, transcript: portable, transition: .init(expectedEpoch: held.epoch, route: next, transcript: portable))).value(Transcript.self)
      }
      try await harness.store.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 0, totalTokens: 10)))
      #expect(try await warmer.allows(id))
      #expect(try await warmer.allows(otherID))
    }
  }
}

extension GroupSwitchingTests {
  @Test func removedGroupPreservesTypedErrorWithoutRecordingRefusal() async throws {
    try await withSessionDeps {
      let (harness, owner, _, id) = try await setup()
      let held = try #require(await owner.modelRoute(id))
      let fs = await harness.space.fs(.shared)
      let (entry, _) = try await fs.read(ModelsDocument.groupPath)
      _ = try await fs.write(ModelsDocument.groupPath, Data("{}".utf8), ifMatch: entry)
      let catalog = try await groupCatalog(owner: owner)()
      let error = CatalogError.modelRouteInvalid(group: "work", member: "a")
      #expect(try await recordRouteFailure(error, session: id, owner: owner, catalog: catalog, inferenceStarted: false) == nil)
      let infer = kernelInference(owner: owner, catalog: { catalog }, groupCatalog: { catalog }, sockets: .init(), attempts: .init(), usage: harness.runtime.usage)
      let transcript = try await harness.store.transcript(id)
      await #expect(throws: error) {
        try await infer(.init(sessionID: id, attemptID: UUID(), transcript: transcript, mode: .normal))
      }
      try await harness.running {
        try await harness.deliver("request after removal", to: id)
        try await until("invalidated group error") { try await harness.store.record(id).work == .errored }
        #expect(try await harness.store.record(id).errorMessage != nil)
        #expect(try await harness.store.modelRoute(id) == held)
      }
    }
  }

  @Test func actualCredentialRefreshRefusalHandsOffAndInferenceOnlyResolvesHeldReplacement() async throws {
    try await withSessionDeps {
      let revoked = Mutex(false)
      let emitted = Mutex<[String]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let round = emitted.withLock { $0.append(request.headers.sensitiveValues["authorization"] ?? ""); return $0.count }
          var event = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"replacement\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
          if round == 2 {
            event = [
              #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_compact","call_id":"compact_b","name":"compact","arguments":""}}"#,
              #"{"type":"response.function_call_arguments.done","item_id":"fc_compact","arguments":"{\"summary\":\"Replacement account continues safely\",\"pre_reads\":[\"/task.md\"]}"}"#,
              #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_compact","call_id":"compact_b","name":"compact","arguments":"{\"summary\":\"Replacement account continues safely\",\"pre_reads\":[\"/task.md\"]}"}}"#,
            ].map { "data: \($0)\n\n" }.joined() + event
          }
          return Response(status: .ok, body: .bytes(Data(event.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in
          if provider == "testing", revoked.withLock({ $0 }) { throw ChatGPTAuthError.loginRequired(detail: "offline revoked fixture") }
          return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
        })
        try await ModelGroupRouteTests().install(harness)
        let fs = await harness.space.fs(.shared)
        let (entry, data) = try await fs.read(ModelsDocument.groupPath)
        var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
        groups["work"]!.policy = .quotaAware(holdDownSeconds: 0)
        _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
        let created = try await harness.call("/v1/session", .object(["title": "Refresh switch", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        revoked.withLock { $0 = true }
        try await harness.running {
          try await harness.deliver("request after revoked credential", to: id)
          try await until("replacement account inferred") { try await harness.store.record(id).work == .noWork && emitted.withLock { $0.count } == 1 }
          let route = try #require(await harness.store.modelRoute(id))
          #expect(route.member == "b")
          #expect(route.switchCause == .authentication)
          #expect(route.failure == nil)
          #expect(emitted.withLock { $0 } == ["Bearer key-alternate"])
          try await harness.deliver("replacement remains usable", to: id)
          try await until("held replacement compacted and inferred again") { try await harness.store.record(id).work == .noWork && emitted.withLock { $0.count } == 3 }
          #expect(try await harness.store.modelRoute(id) == route)
          #expect(try await harness.store.generationState(id).generation == 2)
          let compacted = try await harness.store.transcript(id)
          guard case let .generationHead(head) = compacted.items[0] else { Issue.record("missing compacted head"); return }
          #expect(head.summary == "Replacement account continues safely")
          #expect(head.snapshot.preReads == ["/task.md"])
          #expect(emitted.withLock { $0 } == Array(repeating: "Bearer key-alternate", count: 3))
        }
      }
    }
  }

  @Test func warmingIgnoresExpiredInactiveAndSupersededRefusals() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, owner, catalog, id) = try await setup()
        let fs = await harness.space.fs(.shared)
        let (entry, data) = try await fs.read(ModelsDocument.spacePath)
        var document = try ModelsDocument(json: data)
        document.providers["testing"]!.models["test-model"]!.cacheWarming = .init(floorTokens: 1)
        _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: entry)
        let other = try await harness.call("/v1/session", .object(["title": "Peer", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let otherID = SessionID(other.id)
        for session in [id, otherID] { try await harness.store.appendAssistant(session, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 0, totalTokens: 10))) }
        let warmer = CacheWarmer(space: harness.space, usage: harness.runtime.usage)
        _ = try await recordRouteFailure(InferenceError.rateLimited(retryAt: now.withLock { $0.addingTimeInterval(600) }), session: id, owner: owner, catalog: catalog)
        #expect(try await warmer.allows(otherID) == false)
        now.withLock { $0 = $0.addingTimeInterval(601) }
        #expect(try await warmer.allows(otherID))
        #expect(try await warmer.allows(id))
        _ = try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, owner: owner, catalog: catalog)
        #expect(try await warmer.allows(otherID) == false)
        try await harness.store.markInterrupted(id)
        #expect(try await warmer.allows(otherID))
        try await harness.store.markResumed(id)
        #expect(try await warmer.allows(otherID) == false)
        _ = try await harness.store.archive(id, grace: .seconds(60))
        #expect(try await warmer.allows(otherID))
        try await harness.store.unarchive(id)
        #expect(try await warmer.allows(otherID) == false)
        now.withLock { $0 = $0.addingTimeInterval(1) }
        try await harness.space.recordInference(.init(id: "recovered-account", session: otherID, at: now.withLock { $0 }, provider: "testing", model: "test-model", effort: "high", outcome: "ok"))
        #expect(try await warmer.allows(otherID))
        #expect(try await warmer.allows(id))
        now.withLock { $0 = $0.addingTimeInterval(1) }
        let repeated = try #require(await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, owner: owner, catalog: catalog))
        #expect(repeated.lastFailureAt == now.withLock { $0 })
        #expect(try await warmer.allows(otherID) == false)
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test func unusedQuotaRefusalIsNotACandidateButMissingCredentialRemainsTyped() async throws {
    try await withSessionDeps {
      let (harness, owner, source, id) = try await setup()
      var quota = source
      quota.credentials = .bound { provider in
        if provider == "alternate" { throw InferenceError.rateLimited(retryAt: nil) }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let ready = quota
      let transcript = try await harness.store.transcript(id).compacted(head: .init(id: UUID(), timestamp: Date(), summary: "summary", snapshot: .init(), runningWork: []), kept: nil)
      let prepare = compactionPlacement(owner: owner, catalog: { ready }, usage: harness.runtime.usage)
      #expect(try await prepare(id, transcript, nil) == nil)
      var missing = source
      missing.credentials = .bound { provider in
        if provider == "alternate" { return nil }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let unavailable = missing
      let invalid = compactionPlacement(owner: owner, catalog: { unavailable }, usage: harness.runtime.usage)
      await #expect(throws: CatalogError.groupMember(group: "work", member: "b", reason: .missingCredential(provider: "alternate"))) { try await invalid(id, transcript, nil) }
    }
  }
}

extension GroupSwitchingTests {
  @Test(arguments: [false, true]) func lastResortSkipsLapsedCandidateAtReadinessOrLateResolve(lateRefresh: Bool) async throws {
    try await withSessionDeps {
      let (harness, owner, _, id) = try await setup(seconds: 0)
      let fs = await harness.space.fs(.shared)
      let (entry, data) = try await fs.read(ModelsDocument.spacePath)
      var document = try ModelsDocument(json: data)
      document.providers["third"] = document.providers["testing"]
      _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: entry)
      let (groupEntry, groupData) = try await fs.read(ModelsDocument.groupPath)
      var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: groupData)
      groups["work"]!.members.append(.init(id: "c", provider: "third", model: "test-model"))
      _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: groupEntry)
      let bResolutions = Mutex(0)
      var catalog = try await groupCatalog(owner: owner)()
      catalog.credentials = .bound { provider in
        if provider == "alternate" {
          let call = bResolutions.withLock { $0 += 1; return $0 }
          if !lateRefresh || call > 1 { throw ChatGPTAuthError.loginRequired(detail: "lapsed alternate") }
        }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      _ = try await recordRouteFailure(InferenceError.rateLimited(retryAt: Date().addingTimeInterval(18000)), session: id, owner: owner, catalog: catalog)
      let held = try #require(await owner.modelRoute(id))
      do {
        try await routeWaitOrSwitch(held, session: id, catalog: catalog, usage: harness.runtime.usage)
        Issue.record("missing last-resort boundary")
      } catch let boundary as ReplayBoundaryRequired {
        let next = try #require(boundary.route)
        #expect(next.member == "c")
        #expect(next.specifier.provider == "third")
        #expect(next.switchCause == .quota)
        #expect(bResolutions.withLock { $0 } == (lateRefresh ? 2 : 1))
        let hydration = try await owner.hydrate(id)
        guard case let .kernel(source) = hydration.transcript else { Issue.record("not kernel"); return }
        let portable = try source.portableHandoff(binding: boundary.binding, budget: boundary.budget, runningWork: [])
        _ = try await owner.append(id, .portableHandoff(expectedGeneration: hydration.generation, source: source, transcript: portable, transition: .init(expectedEpoch: held.epoch, route: next, transcript: portable))).value(Transcript.self)
        #expect(try await owner.modelRoute(id) == next)
        #expect(try await harness.store.generationState(id).generation == hydration.generation + 1)
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test func ordinaryCompactionMoveEmitsNoRetainedOldAccountOpaqueItems() async throws {
    try await withSessionDeps {
      let requests = Mutex<[(String, String)]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.text() ?? ""
          let round = requests.withLock { $0.append((request.headers.sensitiveValues["authorization"] ?? "", body)); return $0.count }
          let completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"completed\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n\n"
          let opaque = [
            #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"native-before-compaction","summary":[],"encrypted_content":"signature-before-compaction"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"native-before-compaction","summary":[],"encrypted_content":"signature-before-compaction"}}"#,
          ].map { "data: \($0)\n\n" }.joined()
          return Response(status: .ok, body: .bytes(Data(((round == 1 ? opaque : "") + completed).utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) })
        try await ModelGroupRouteTests().install(harness)
        let created = try await harness.call("/v1/session", .object(["title": "Ordinary move", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        try await harness.running {
          try await harness.deliver("retained input", to: id)
          try await until("old account output committed") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 1 }
        }
        let source = try await harness.store.transcript(id)
        #expect(String(decoding: try JSONEncoder().encode(source), as: UTF8.self).contains("signature-before-compaction"))
        let owner = Hub(space: harness.space, credentials: harness.credentials)
        let catalog = try await groupCatalog(owner: owner)()
        let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
        harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset)], at: Date())
        harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset)], at: Date())
        let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "preserved ordinary summary", snapshot: .init(preReads: ["/task.md"]), runningWork: ["exec.running"])
        let kept = 1 ..< source.items.count
        let compacted = source.compacted(head: head, kept: kept)
        let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
        let transition = try #require(await prepare(id, compacted, nil))
        #expect(transition.route.member == "b")
        #expect(transition.route.switchCause == nil)
        let committed = try await owner.append(id, .compacted(closing: nil, head: head, kept: kept, completing: nil, transition: transition)).value(Transcript.self)
        let infer = kernelInference(owner: owner, catalog: { catalog }, groupCatalog: { catalog }, sockets: .init(), attempts: .init(), usage: harness.runtime.usage)
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: committed, mode: .normal))
        let emitted = requests.withLock { $0 }
        #expect(emitted.count == 2)
        #expect(emitted[1].0 == "Bearer key-alternate")
        #expect(!emitted[1].1.contains("signature-before-compaction"))
        #expect(!emitted[1].1.contains("native-before-compaction"))
        #expect(emitted[1].1.contains("preserved ordinary summary"))
        #expect(emitted[1].1.contains("retained input"))
      }
    }
  }

  @Test func inspectionEndpointDatesAreISO8601UTCStrings() async throws {
    try await withSessionDeps {
      let (harness, owner, _, _) = try await setup()
      let instant = Date(timeIntervalSince1970: 10000)
      let reset = instant.addingTimeInterval(18000)
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 10, resetsAt: reset.timeIntervalSince1970)], at: instant)
      let created = try await harness.call("/v1/session", .object(["title": "Date inspection", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let id = SessionID(created.id)
      let held = try #require(await owner.modelRoute(id))
      let failure = ModelRouteFailure(reason: .quota, firstFailureAt: instant, deadline: instant.addingTimeInterval(1800), retryAt: instant.addingTimeInterval(18000), lastFailureAt: instant.addingTimeInterval(1))
      try await owner.append(id, .modelRouteFailureUpdated(expectedEpoch: held.epoch, failure: failure)).value(Void.self)
      let inspected = try await harness.get("/v1/session/\(id.rawValue)/model-route").body.json(SessionModelRouteOutput.self)
      let route = try #require(inspected.route?.object)
      #expect(route["placedAt"]?.stringValue == held.placedAt.ISO8601Format())
      let episode = try #require(route["failure"]?.object)
      #expect(episode["firstFailureAt"]?.stringValue == instant.ISO8601Format())
      #expect(episode["lastFailureAt"]?.stringValue == instant.addingTimeInterval(1).ISO8601Format())
      #expect(episode["deadline"]?.stringValue == instant.addingTimeInterval(1800).ISO8601Format())
      #expect(episode["retryAt"]?.stringValue == instant.addingTimeInterval(18000).ISO8601Format())
      let decisions = try #require(inspected.decisions?.array)
      #expect(decisions.count == 1)
      #expect(decisions[0].object?["placedAt"]?.stringValue == held.placedAt.ISO8601Format())
      #expect(route["placedAt"]?.stringValue?.hasSuffix("Z") == true)
      for item in [inspected.route!, decisions[0]] {
        let evidence = try #require(item.object?["evidence"]?.array?.first(where: { $0.object?["member"]?.stringValue == "a" })?.object)
        #expect(evidence["observedAt"]?.stringValue == instant.ISO8601Format())
        let window = try #require(evidence["windows"]?.array?.first?.object)
        #expect(window["resetsAt"]?.stringValue == reset.ISO8601Format())
      }
      #expect(try await owner.modelRoute(id)?.evidence.first(where: { $0.member == "a" })?.observedAt == instant.timeIntervalSince1970)
    }
  }
}
