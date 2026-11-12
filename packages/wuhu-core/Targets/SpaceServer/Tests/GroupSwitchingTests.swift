import Credentials
import Dependencies
import DeterministicDependencies
import ExecutionOwner
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import LoopCore
import class MainHub.Hub
import ModelProviders
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

@Suite(.deterministicDependencies) struct GroupSwitchingTests {
  func setup(policy: ModelsDocument.Policy = .quotaAware, model: String = "test-model") async throws -> (SessionHarness, Hub, ProviderCatalog, SessionID) {
    let harness = try await SessionHarness(credentials: .bound { provider in
      .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
    })
    try await ModelGroupRouteTests().install(harness, model: model)
    let fs = await harness.space.fs(.settings)
    let (entry, data) = try await fs.read(ModelsDocument.groupPath)
    var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
    groups["work"]!.policy = policy
    _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
    let owner = Hub(space: harness.space)
    let catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
    let created = try await harness.call("/v1/session", .object(["title": "Switch", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
    return (harness, owner, catalog, SessionID(created.id))
  }

  @Test func durableEpisodeKeepsFirstFailureAndSuccessClearsIt() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, owner, catalog, id) = try await setup()
        let pin = try #require(await owner.space.sessions.modelRoute(id))
        let first = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: nil), session: id, store: owner.space.sessions, catalog: catalog))
        now.withLock { $0 = Date(timeIntervalSince1970: 11000) }
        let repeated = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: nil), session: id, store: owner.space.sessions, catalog: catalog))
        #expect(repeated.firstFailureAt == first.firstFailureAt)
        #expect(repeated.lastFailureAt == Date(timeIntervalSince1970: 11000))
        #expect(repeated.consecutiveFailures == 2)
        let held = try #require(await harness.store.modelRoute(id))
        #expect(held.failure == repeated)
        try await owner.space.sessions.updateModelRouteFailure(id, expectedEpoch: held.epoch, failure: nil)
        #expect(try await owner.space.sessions.modelRoute(id)?.failure == nil)
        #expect(try await harness.store.modelRouteHistory(id) == [pin])
      }
    }
  }

  @Test func onlyActualTypedRefusalsOrThirdOutageQualifyAndSelectNeverRecords() async throws {
    try await withSessionDeps {
      let (_, owner, catalog, id) = try await setup()
      for error in [InferenceError.invalidInput(status: 403, body: "model permission"), .contextTooLong, .cancelled, .malformedModelMessage(message: "bad", reason: nil), .transient(status: nil, body: "parser"), .other(status: nil, body: "config"), .transport(.connectionClosed), .transport(.readTimeout), .transport(.idleTimeout)] {
        #expect(try await recordRouteFailure(error, session: id, store: owner.space.sessions, catalog: catalog) == nil)
      }
      #expect(try await recordRouteFailure(CatalogError.unknownModel(provider: "testing", model: "typo"), session: id, store: owner.space.sessions, catalog: catalog) == nil)
      let outages: [InferenceError] = [.transient(status: 503, body: nil), .upstreamUnavailable(code: "overloaded_error"), .transient(status: 529, body: nil)]
      for (index, error) in outages.enumerated() {
        let count = index + 1
        let failure = try #require(await recordRouteFailure(error, session: id, store: owner.space.sessions, catalog: catalog))
        #expect(failure.consecutiveFailures == count)
        #expect(failure.refusing == (count == 3))
      }
      let (_, selectOwner, selectCatalog, selectID) = try await setup(policy: .select(member: "a"))
      #expect(try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: selectID, store: selectOwner.space.sessions, catalog: selectCatalog) == nil)
    }
  }

  @Test func ordinaryCompactionUsesHeadroomPreservesSummaryAndAvoidsSamePinChurn() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup()
      let old = try #require(await owner.space.sessions.modelRoute(id))
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: String(repeating: "important summary ", count: 50), snapshot: .init(preReads: ["/task.md"]), runningWork: ["exec.running"])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
      #expect(try await prepare(id, tokens, nil) == nil)
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: Date().timeIntervalSince1970 + 18000), .init(name: "seven_day", usedPercent: 99, resetsAt: nil)], at: Date())
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: Date().timeIntervalSince1970 + 18000), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: Date())
      let transition = try #require(await prepare(id, tokens, nil))
      #expect(transition.route.member == "b")
      #expect(transition.route.reason == .compaction)
      #expect(transition.carriesTail)
      #expect(transition.binding?.epoch == transition.route.epoch)
      let committed = try await harness.store.foldLines(id, head: head, transition: transition)
      let expectedHead = head.lines(session: id)
      #expect(committed.prefix(expectedHead.count).map(\.message) == expectedHead.map(\.message))
      #expect(try await owner.space.sessions.modelRoute(id) == transition.route)
      #expect(try await harness.store.modelRouteHistory(id) == [old, transition.route])
      #expect(try await prepare(id, committed.estimatedContextTokens(images: .claude), nil) == nil)
    }
  }

  @Test func authenticationRefusalKeepsTheHeldMember() async throws {
    try await withSessionDeps {
      let (_, owner, catalog, id) = try await setup()
      _ = try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, store: owner.space.sessions, catalog: catalog)
      #expect(try await owner.space.sessions.modelRoute(id)?.member == "a")
    }
  }

  @Test func aPastReportedResetFallsBackToTheUsageBoardReset() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, owner, catalog, id) = try await setup()
        let board = Date(timeIntervalSince1970: 10000 + 7200)
        harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 100, resetsAt: board.timeIntervalSince1970), .init(name: "seven_day", usedPercent: 40, resetsAt: nil)], at: now.withLock { $0 })
        let failure = try #require(await recordRouteFailure(InferenceError.rateLimited(retryAt: Date(timeIntervalSince1970: 9000)), session: id, store: owner.space.sessions, catalog: catalog, usage: harness.runtime.usage))
        #expect(failure.retryAt == board)
        let reported = Date(timeIntervalSince1970: 10000 + 600)
        #expect(try await recordRouteFailure(InferenceError.rateLimited(retryAt: reported), session: id, store: owner.space.sessions, catalog: catalog, usage: harness.runtime.usage)?.retryAt == reported)
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test func aRateLimitedMemberIsWaitedOutPastTheOldHoldDownAndResumedWithoutAnySwitch() async throws {
    try await withSessionDeps {
      let now = Mutex(Date())
      let requests = Mutex<[String]>([])
      try await withDependencies {
        $0.date = DateGenerator { now.withLock { $0 } }
        $0.fetch = FetchClient { request in
          let round = requests.withLock { $0.append(request.headers.sensitiveValues["authorization"] ?? ""); return $0.count }
          if round == 1 {
            var headers = Headers()
            headers[.retryAfter] = "18000"
            return Response(status: .tooManyRequests, headers: headers, body: .string("quota"))
          }
          let completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-a\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n\n"
          return Response(status: .ok, body: .bytes(Data(completed.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) })
        try await ModelGroupRouteTests().install(harness)
        let created = try await harness.call("/v1/session", .object(["title": "Held through quota", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        let original = try #require(await harness.store.modelRoute(id))
        #expect(original.member == "a")
        harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: nil), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: now.withLock { $0 })
        let owner = Hub(space: harness.space)
        let access = InferenceAccess(credentials: harness.credentials)
        let infer = kernelInference(store: owner.space.sessions, executor: try await SessionRuntime.toolExecutor(owner: owner, access: access), access: access, sockets: .init(), usage: harness.runtime.usage)
        var lines = try await harness.store.testLines(id)
        lines.append(.init(at: now.withLock { $0 }, key: "message:outstanding", message: .user(.init(content: [.text("outstanding request")]))))
        let request = InferenceRequest(sessionID: id, attemptID: UUID(), generation: 0, lines: lines)
        await #expect(throws: (any Error).self) { try await infer(request) }
        let failure = try #require(await harness.store.modelRoute(id)?.failure)
        let reset = try #require(failure.retryAt)
        #expect(failure.reason == .quota)
        #expect(reset > failure.firstFailureAt.addingTimeInterval(1800))
        for instant in [failure.firstFailureAt.addingTimeInterval(1800), reset.addingTimeInterval(-1)] {
          now.withLock { $0 = instant }
          do {
            _ = try await infer(request)
            Issue.record("a held member must be waited out until its reset")
          } catch let waiting as ModelRouteWaiting {
            #expect(waiting.retryAt == reset)
          }
        }
        #expect(requests.withLock { $0.count } == 1)
        now.withLock { $0 = reset }
        _ = try await infer(request)
        let resumed = try #require(await harness.store.modelRoute(id))
        #expect(resumed.epoch == original.epoch)
        #expect(resumed.member == "a")
        #expect(resumed.failure == nil)
        #expect(requests.withLock { $0 } == ["Bearer key-testing", "Bearer key-testing"])
        #expect(try await harness.store.modelRouteHistory(id) == [original])
        #expect(try await harness.store.generationState(id).generation == 0)
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test func typedRefreshRefusalOnlyAffectsHeldProvider() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup()
      #expect(try await recordRouteFailure(InferenceError.credentialRefreshRefused(provider: "alternate"), session: id, store: owner.space.sessions, catalog: catalog, inferenceStarted: false) == nil)
      let failure = try #require(await recordRouteFailure(InferenceError.credentialRefreshRefused(provider: "testing"), session: id, store: owner.space.sessions, catalog: catalog, inferenceStarted: false))
      #expect(failure.source == .credentialRefresh)
      #expect(failure.code == "loginRequired")
      let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 80, resetsAt: reset), .init(name: "seven_day", usedPercent: 80, resetsAt: nil)], at: Date())
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: Date())
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "moved", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let transition = try #require(await compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)(id, tokens, nil))
      #expect(transition.route.member == "b")
      _ = try await harness.store.foldLines(id, head: head, transition: transition)
    }
  }
}

extension GroupSwitchingTests {
  @Test func removedGroupPreservesTypedErrorWithoutRecordingRefusal() async throws {
    try await withSessionDeps {
      let (harness, owner, _, id) = try await setup()
      let held = try #require(await owner.space.sessions.modelRoute(id))
      let fs = await harness.space.fs(.settings)
      let (entry, _) = try await fs.read(ModelsDocument.groupPath)
      _ = try await fs.write(ModelsDocument.groupPath, Data("{}".utf8), ifMatch: entry)
      let catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
      let error = CatalogError.modelRouteInvalid(group: "work", member: "a")
      #expect(try await recordRouteFailure(error, session: id, store: owner.space.sessions, catalog: catalog, inferenceStarted: false) == nil)
      let access = InferenceAccess(credentials: harness.credentials)
      let infer = kernelInference(store: owner.space.sessions, executor: try await SessionRuntime.toolExecutor(owner: owner, access: access), access: access, sockets: .init(), usage: harness.runtime.usage)
      let lines = try await harness.store.testLines(id)
      await #expect(throws: error) {
        try await infer(.init(sessionID: id, attemptID: UUID(), generation: 0, lines: lines))
      }
      try await harness.running {
        try await harness.deliver("request after removal", to: id)
        try await until("invalidated group error") { try await harness.store.record(id).work == .errored }
        #expect(try await harness.store.record(id).errorMessage != nil)
        #expect(try await harness.store.modelRoute(id) == held)
      }
    }
  }

  @Test func aCredentialRefreshRefusalErrorsTheSessionOnItsHeldMember() async throws {
    try await withSessionDeps {
      let revoked = Mutex(false)
      let emitted = Mutex<[String]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          emitted.withLock { $0.append(request.headers.sensitiveValues["authorization"] ?? "") }
          let event = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"unexpected\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
          return Response(status: .ok, body: .bytes(Data(event.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in
          if provider == "testing", revoked.withLock({ $0 }) { throw ChatGPTAuthError.loginRequired(detail: "offline revoked fixture") }
          return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
        })
        try await ModelGroupRouteTests().install(harness)
        let created = try await harness.call("/v1/session", .object(["title": "Refresh refusal", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        let original = try #require(await harness.store.modelRoute(id))
        revoked.withLock { $0 = true }
        try await harness.running {
          try await harness.deliver("request after revoked credential", to: id)
          try await until("refusal errors the session") { try await harness.store.record(id).work == .errored }
          let route = try #require(await harness.store.modelRoute(id))
          #expect(route.epoch == original.epoch)
          #expect(route.member == "a")
          #expect(route.failure?.source == .credentialRefresh)
          #expect(emitted.withLock { $0 }.isEmpty)
          #expect(try await harness.store.modelRouteHistory(id) == [original])
        }
      }
    }
  }

  @Test func aRepeatedRefusalStampsTheLastFailure() async throws {
    try await withSessionDeps {
      let now = Mutex(Date(timeIntervalSince1970: 10000))
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let (harness, _, catalog, id) = try await setup()
        _ = try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, store: harness.store, catalog: catalog)
        now.withLock { $0 = $0.addingTimeInterval(1) }
        let repeated = try #require(await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, store: harness.store, catalog: catalog))
        #expect(repeated.lastFailureAt == now.withLock { $0 })
        #expect(repeated.consecutiveFailures == 2)
      }
    }
  }
}

extension GroupSwitchingTests {
  @Test(arguments: [CompactionTarget?.none, CompactionTarget(model: "work")]) func compactionKeepsTheHeldMemberAgainstAFivePercentLead(target: CompactionTarget?) async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup()
      let held = try #require(await owner.space.sessions.modelRoute(id))
      #expect(held.member == "a")
      let reset = Date().timeIntervalSince1970 + 18000
      for (provider, weekly) in [("testing", 50.0), ("alternate", 47.5)] {
        harness.runtime.usage.record(provider, plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: weekly, resetsAt: nil)], at: Date())
      }
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "stay", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      #expect(try await compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)(id, tokens, target) == nil)
      #expect(try await owner.space.sessions.modelRoute(id) == held)
    }
  }

  @Test func unusedQuotaRefusalIsNotACandidateButMissingCredentialRemainsTyped() async throws {
    try await withSessionDeps {
      let (harness, owner, source, id) = try await setup()
      var quota = source
      quota.credentials = .bound { provider in
        if provider == "alternate" { throw InferenceError.rateLimited(retryAt: nil) }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let ready = quota
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "summary", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in ready }, usage: harness.runtime.usage)
      #expect(try await prepare(id, tokens, nil) == nil)
      var missing = source
      missing.credentials = .bound { provider in
        if provider == "alternate" { return nil }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let unavailable = missing
      let invalid = compactionPlacement(store: owner.space.sessions, catalog: { _ in unavailable }, usage: harness.runtime.usage)
      await #expect(throws: CatalogError.groupMember(group: "work", member: "b", reason: .missingCredential(provider: "alternate"))) { try await invalid(id, tokens, nil) }
    }
  }
}

extension GroupSwitchingTests {
  @Test(arguments: [false, true]) func compactionSkipsLapsedCandidateAtReadinessOrLateResolve(lateRefresh: Bool) async throws {
    try await withSessionDeps {
      let (harness, owner, _, id) = try await setup()
      let fs = await harness.space.fs(.settings)
      let (entry, data) = try await fs.read(ModelsDocument.spacePath)
      var document = try ModelsDocument(json: data)
      document.providers["third"] = document.providers["testing"]
      _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: entry)
      let (groupEntry, groupData) = try await fs.read(ModelsDocument.groupPath)
      var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: groupData)
      groups["work"]!.members.append(.init(id: "c", provider: "third", model: "test-model"))
      _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: groupEntry)
      let bResolutions = Mutex(0)
      var catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
      catalog.credentials = .bound { provider in
        if provider == "alternate" {
          let call = bResolutions.withLock { $0 += 1; return $0 }
          if !lateRefresh || call > 1 { throw ChatGPTAuthError.loginRequired(detail: "lapsed alternate") }
        }
        return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
      for (provider, used) in [("testing", 99.0), ("alternate", 0), ("third", 50)] {
        harness.runtime.usage.record(provider, plan: nil, windows: [.init(name: "five_hour", usedPercent: used, resetsAt: reset), .init(name: "seven_day", usedPercent: used, resetsAt: nil)], at: Date())
      }
      let ready = catalog
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "moved", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let transition = try #require(await compactionPlacement(store: owner.space.sessions, catalog: { _ in ready }, usage: harness.runtime.usage)(id, tokens, nil))
      #expect(transition.route.member == "c")
      #expect(transition.route.specifier.provider == "third")
      #expect(bResolutions.withLock { $0 } == (lateRefresh ? 2 : 1))
      let generation = try await harness.store.generationState(id).generation
      _ = try await harness.store.foldLines(id, head: head, transition: transition)
      #expect(try await owner.space.sessions.modelRoute(id) == transition.route)
      #expect(try await harness.store.generationState(id).generation == generation + 1)
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
          try await until("old account output committed") { try await harness.store.settledWork(id) && requests.withLock { $0.count } == 1 }
        }
        let stored = try await harness.store.transcriptLines(id)
        let source = try stored.map { try $0.line() }
        #expect(String(decoding: try JSONEncoder().encode(source), as: UTF8.self).contains("signature-before-compaction"))
        let owner = Hub(space: harness.space)
        let catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
        let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
        harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset), .init(name: "seven_day", usedPercent: 99, resetsAt: nil)], at: Date())
        harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: Date())
        let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "preserved ordinary summary", snapshot: .init(preReads: ["/task.md"]), runningWork: ["exec.running"])
        let first = try #require(stored.first { !$0.key.hasPrefix(LineKey.head) }?.position)
        let last = try #require(stored.last?.position)
        let kept = first ..< (last + 1)
        let carried = try stored.filter { kept.contains($0.position) }.compactMap { try $0.line().carried(portable: false) }
        let tokens = (head.lines(session: id) + carried).estimatedContextTokens(images: .claude)
        let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
        let transition = try #require(await prepare(id, tokens, nil))
        #expect(transition.route.member == "b")
        #expect(transition.carriesTail)
        #expect(transition.binding?.epoch == transition.route.epoch)
        let committed = try await harness.store.foldLines(id, head: head, kept: kept, transition: transition)
        #expect(committed.allSatisfy { $0.meta == nil })
        let access = InferenceAccess(credentials: harness.credentials)
        let infer = kernelInference(store: owner.space.sessions, executor: try await SessionRuntime.toolExecutor(owner: owner, access: access), access: access, sockets: .init(), usage: harness.runtime.usage)
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), generation: 1, lines: committed, binding: transition.binding))
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
      let reset = Date().addingTimeInterval(18000)
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 10, resetsAt: reset.timeIntervalSince1970), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: instant)
      let created = try await harness.call("/v1/session", .object(["title": "Date inspection", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let id = SessionID(created.id)
      let held = try #require(await owner.space.sessions.modelRoute(id))
      let failure = ModelRouteFailure(reason: .quota, firstFailureAt: instant, retryAt: instant.addingTimeInterval(18000), lastFailureAt: instant.addingTimeInterval(1))
      try await owner.space.sessions.updateModelRouteFailure(id, expectedEpoch: held.epoch, failure: failure)
      let inspected = try await harness.get("/v1/session/\(id.rawValue)/model-route").body.json(SessionModelRouteOutput.self)
      let route = try #require(inspected.route?.object)
      #expect(route["placedAt"]?.stringValue == held.placedAt.ISO8601Format())
      let episode = try #require(route["failure"]?.object)
      #expect(episode["firstFailureAt"]?.stringValue == instant.ISO8601Format())
      #expect(episode["lastFailureAt"]?.stringValue == instant.addingTimeInterval(1).ISO8601Format())
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
      #expect(try await owner.space.sessions.modelRoute(id)?.evidence.first(where: { $0.member == "a" })?.observedAt == instant.timeIntervalSince1970)
    }
  }
}

extension GroupSwitchingTests {
  @Test(arguments: [ModelRouteFailure.Reason.authentication, .quota]) func startOverLeavesOutAHeldMemberOnlyWhileItIsRefusedForAuthentication(reason: ModelRouteFailure.Reason) async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await setup()
      let error: InferenceError = reason == .authentication ? .authenticationRefused(code: "invalid_api_key") : .rateLimited(retryAt: nil)
      #expect(try await recordRouteFailure(error, session: id, store: owner.space.sessions, catalog: catalog)?.reason == reason)
      let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
      for (provider, used) in [("testing", 0.0), ("alternate", 90)] {
        harness.runtime.usage.record(provider, plan: nil, windows: [.init(name: "five_hour", usedPercent: used, resetsAt: reset), .init(name: "seven_day", usedPercent: used, resetsAt: nil)], at: Date())
      }
      let restarted = try await harness.call("/v1/session/\(id.rawValue)/restart", .null, as: SessionRestartOutput.self)
      try await until("placed for the start over") { try await owner.space.sessions.modelRoute(id)?.reason == .startOver }
      let placed = try #require(await owner.space.sessions.modelRoute(id))
      #expect(placed.member == (reason == .authentication ? "b" : "a"))
      #expect(restarted.provider == placed.specifier.provider)
      #expect(placed.reason == .startOver)
      #expect(placed.failure == nil)
    }
  }

  @Test(arguments: [false, true]) func compactionPlacesAwayFromAHeldMemberRefusedForAuthentication(loginLapsed: Bool) async throws {
    try await withSessionDeps {
      let (harness, owner, source, id) = try await setup()
      var catalog = source
      if loginLapsed {
        catalog.credentials = .bound { provider in
          if provider == "testing" { throw ChatGPTAuthError.loginRequired(detail: "lapsed held account") }
          return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
        }
      } else {
        _ = try await recordRouteFailure(InferenceError.authenticationRefused(code: "invalid_api_key"), session: id, store: owner.space.sessions, catalog: catalog)
      }
      let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
      for (provider, used) in [("testing", 0.0), ("alternate", 90)] {
        harness.runtime.usage.record(provider, plan: nil, windows: [.init(name: "five_hour", usedPercent: used, resetsAt: reset), .init(name: "seven_day", usedPercent: used, resetsAt: nil)], at: Date())
      }
      let ready = catalog
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "moved", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let transition = try #require(await compactionPlacement(store: owner.space.sessions, catalog: { _ in ready }, usage: harness.runtime.usage)(id, tokens, nil))
      #expect(transition.route.member == "b")
      #expect(transition.route.failure == nil)
    }
  }
}
