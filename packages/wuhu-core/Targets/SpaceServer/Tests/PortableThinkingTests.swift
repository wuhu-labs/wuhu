import Credentials
import Dependencies
import DeterministicDependencies
import ExecutionOwner
import Fetch
import Foundation
import InferenceKit
import JSONValue
import LoopCore
import class MainHub.Hub
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

private let portableTextSSE = """
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"index":0,"delta":{"type":"text_delta","text":"completed"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}


"""

private enum ThinkingBoundary: String, CaseIterable, Sendable {
  case legacyAdoption, credentialIdentity, providerConfiguration, compaction
}

func thinkingHistory(binding: ReplayBinding?, scope: String?, signed: Bool = true) -> [TranscriptItem] {
  let call = ToolCall(id: "completed_call", name: "read", arguments: .object(["path": "/task.md"]))
  return [
    .direct(.init(id: UUID(), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "finish this task"))),
    .assistant(.init(id: UUID(), timestamp: Date(), content: (signed ? [
      .reasoning(.encrypted(.init(providerID: "anthropic", model: "test-model", summary: "portable summary", opaque: "OLD_SIGNATURE", replayScope: scope))),
    ] : []) + [.toolCall(call)], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [call.id: .init(call.id)], replayBinding: binding)),
    .toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init(call.id)), payload: .failure(.init(message: "committed receipt")))),
  ]
}

@Suite(.deterministicDependencies) struct PortableThinkingTests {
  /// `claude` is a Claude model behind a non-Anthropic host (the one named
  /// downgrade); `deepseek` and `mimo` (a non-Claude model on a `claude`-dialect
  /// host) keep their effort.
  @Test(arguments: ThinkingBoundary.allCases, ["claude", "deepseek", "mimo"])
  fileprivate func portableBoundaryKeepsCurrentTurnRunningAndNextInputRestoresThinking(boundary: ThinkingBoundary, flavor: String) async throws {
    try await withSessionDeps {
      let bodies = Mutex<[JSONValue]>([])
      let urls = Mutex<[URL]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.json(JSONValue.self) ?? .null
          bodies.withLock { $0.append(body) }
          urls.withLock { $0.append(request.url) }
          return Response(status: .ok, body: .bytes(Data(portableTextSSE.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let provider = flavor == "deepseek" ? "deepseek" : "testing"
        let modelName = flavor == "claude" ? "claude-test-model" : "test-model"
        let models = switch flavor {
        case "deepseek": testModelsJSON.replacingOccurrences(of: "\"testing\"", with: "\"deepseek\"")
        case "claude": testModelsJSON.replacingOccurrences(of: "\"test-model\"", with: "\"claude-test-model\"")
        default: testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"claude\"")
        }
        let duringTurn: String? = switch flavor {
        case "deepseek": "enabled"
        case "claude": nil
        default: "adaptive"
        }
        let identity = Mutex("old-account")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { _ in .init(credential: .apiKey("fake"), identityEpoch: identity.withLock { $0 }) })
        let id = try await harness.createSession(provider: provider, model: modelName)
        let owner = Hub(space: harness.space)
        let initialCatalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
        guard case let .kernel(specifier) = try await owner.record(id).executor else { Issue.record("expected kernel"); return }
        let held = try await owner.append(id, .modelRouteEstablished(.init(group: nil, member: nil, specifier: specifier, bindingFingerprint: initialCatalog.document.providers[provider]!.routeFingerprint, epoch: UUID().uuidString, reason: .create, placedAt: Date(), evidence: []))).value(SessionModelRoute.self)
        let old = try await initialCatalog.resolve(held.specifier, session: id, routeEpoch: held.epoch)
        let oldBinding: ReplayBinding? = boundary == .legacyAdoption ? nil : .init(identity: old.bindingIdentity, epoch: old.routeEpoch)
        if boundary == .credentialIdentity { identity.withLock { $0 = "new-account" } }
        if boundary == .providerConfiguration {
          let fs = await harness.space.fs(.shared)
          let (entry, _) = try await fs.read("/models.json")
          _ = try await fs.write("/models.json", Data(models.replacingOccurrences(of: "localhost:1", with: "localhost:2").utf8), ifMatch: entry)
        }
        let catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
        let resolved = try await catalog.resolve(held.specifier, session: id, routeEpoch: held.epoch)
        let target = ReplayBinding(identity: resolved.bindingIdentity, epoch: resolved.routeEpoch)
        var source = try await harness.store.transcript(id)
        let items = thinkingHistory(binding: oldBinding, scope: oldBinding?.identity, signed: boundary != .compaction)
        source.items += items
        try await harness.store.append(id, items: items, inputOrigin: source.cacheWarmingInputOrigin)
        let access = InferenceAccess(credentials: harness.credentials)
        let infer = kernelInference(owner: owner, executor: SessionRuntime.toolExecutor(owner: owner, access: access), access: access, sockets: .init(), attempts: .init(), usage: harness.runtime.usage)
        var adopted: Transcript
        if boundary == .compaction {
          adopted = try await owner.append(id, .compacted(closing: nil, head: .init(id: UUID(), timestamp: Date(), summary: "ordinary compaction", snapshot: .init(), replayBinding: target, runningWork: []), kept: 0 ..< source.items.count, completing: nil, transition: nil)).value(Transcript.self)
        } else {
          do {
            _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: source, mode: .normal))
            Issue.record("expected a replay boundary before inference")
            return
          } catch let required as ReplayBoundaryRequired {
            #expect(bodies.withLock { $0.isEmpty })
            let portable = try source.portableHandoff(binding: required.binding, budget: required.budget, runningWork: [])
            adopted = try await owner.append(id, .portableHandoff(expectedGeneration: 0, source: source, transcript: portable, transition: nil)).value(Transcript.self)
          }
        }
        // Rehydrate to prove the decision is not ephemeral executor state.
        adopted = try await harness.store.transcript(id)
        let first = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: adopted, mode: .normal))
        #expect(first.message.content.contains(.text("completed")))
        #expect(try #require(bodies.withLock { $0.last }).object?["thinking"]?.object?["type"]?.stringValue == duringTurn)
        #expect(!bodies.withLock { $0.last!.jsonString() }.contains("OLD_SIGNATURE"))

        let nextCall = ToolCall(id: "continued_call", name: "read", arguments: .object([:]))
        let continued = adopted.appendAssistant(.init(content: [.toolCall(nextCall)]), id: UUID(), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2)), replayBinding: first.replayBinding)
        let kernelCall = try #require(continued.toolCalls.first)
        adopted.append(.toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init(kernelCall.id)), payload: .failure(.init(message: "second committed receipt")))))
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: adopted, mode: .normal))
        #expect(try #require(bodies.withLock { $0.last }).object?["thinking"]?.object?["type"]?.stringValue == duringTurn)

        adopted.append(.message(.init(id: UUID(), messageID: .init("new-input"), conversationID: .init(id.rawValue), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "a fresh turn"))))
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: adopted, mode: .normal))
        let emitted = bodies.withLock { $0 }
        #expect(emitted.count == 3)
        #expect(emitted.last?.object?["thinking"]?.object?["type"]?.stringValue == (flavor == "deepseek" ? "enabled" : "adaptive"))
        #expect(emitted.allSatisfy { $0.object?["model"]?.stringValue == modelName })
        #expect(Set(urls.withLock { $0 }).count == 1)
      }
    }
  }
}

extension PortableThinkingTests {
  @Test(arguments: [false, true])
  func groupPlacementAndLastResortSwitchKeepPortableToolTurnRunning(lastResort: Bool) async throws {
    try await withSessionDeps {
      let bodies = Mutex<[JSONValue]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.json(JSONValue.self) ?? .null
          bodies.withLock { $0.append(body) }
          return Response(status: .ok, body: .bytes(Data(portableTextSSE.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let (harness, owner, catalog, id) = try await GroupSwitchingTests().setup(model: "claude-test-model")
        let held = try #require(await owner.modelRoute(id))
        let resolved = try await catalog.resolve(held.specifier, session: id, routeEpoch: held.epoch)
        var source = try await harness.store.transcript(id)
        let items = thinkingHistory(binding: .init(identity: resolved.bindingIdentity, epoch: resolved.routeEpoch), scope: resolved.replayScope)
        source.items += items
        try await harness.store.append(id, items: items, inputOrigin: source.cacheWarmingInputOrigin)
        let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
        harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset)], at: Date())
        harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset)], at: Date())
        if lastResort {
          let failure = ModelRouteFailure(reason: .quota, firstFailureAt: Date().addingTimeInterval(-1900), deadline: Date().addingTimeInterval(-100), retryAt: nil)
          try await owner.append(id, .modelRouteFailureUpdated(expectedEpoch: held.epoch, failure: failure)).value(Void.self)
          let refusing = try #require(await owner.modelRoute(id))
          do {
            try await routeWaitOrSwitch(refusing, session: id, catalog: catalog, usage: harness.runtime.usage)
            Issue.record("expected last-resort boundary")
            return
          } catch let boundary as ReplayBoundaryRequired {
            let portable = try source.portableHandoff(binding: boundary.binding, budget: boundary.budget, runningWork: [])
            let route = try #require(boundary.route)
            _ = try await owner.append(id, .portableHandoff(expectedGeneration: 0, source: source, transcript: portable, transition: .init(expectedEpoch: held.epoch, route: route, transcript: portable))).value(Transcript.self)
          }
        } else {
          let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "compacted", snapshot: .init(), runningWork: [])
          let compacted = source.compacted(head: head, kept: 0 ..< source.items.count)
          let transition = try #require(await compactionPlacement(owner: owner, catalog: { _ in catalog }, usage: harness.runtime.usage)(id, compacted, nil))
          _ = try await owner.append(id, .compacted(closing: nil, head: head, kept: 0 ..< source.items.count, completing: nil, transition: transition)).value(Transcript.self)
        }
        #expect(try await owner.modelRoute(id)?.member == "b")
        let access = InferenceAccess(credentials: harness.credentials)
        let infer = kernelInference(owner: owner, executor: SessionRuntime.toolExecutor(owner: owner, access: access), access: access, sockets: .init(), attempts: .init(), usage: harness.runtime.usage)
        var adopted = try await harness.store.transcript(id)
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: adopted, mode: .normal))
        #expect(bodies.withLock { $0.last?.object?["thinking"] } == nil)
        #expect(!bodies.withLock { $0.last!.jsonString() }.contains("OLD_SIGNATURE"))
        adopted.append(.direct(.init(id: UUID(), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "new turn"))))
        _ = try await infer(.init(sessionID: id, attemptID: UUID(), transcript: adopted, mode: .normal))
        #expect(bodies.withLock { $0.last?.object?["thinking"]?.object?["type"]?.stringValue } == "adaptive")
        #expect(try await owner.modelRoute(id)?.member == "b")
      }
    }
  }
}
