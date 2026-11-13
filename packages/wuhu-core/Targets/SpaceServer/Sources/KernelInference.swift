import Dependencies
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import class JSONValue.JSONValueDecoder
import Logging
import LoopCore
import ModelProviders
import enum ProviderCapabilities.PlanUsage
import ServerTelemetry
import struct SessionDomain.ImageLimits
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.ReplayBinding
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SessionDomain.TranscriptLine
import struct SessionDomain.WarmingSchedule
import enum SpaceContract.SessionToolExecutor
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionStore
import WuhuAI

func kernelInference(
  store: SessionStore,
  executor: ToolExecutor,
  access: InferenceAccess,
  sockets: ResponsesSocketRegistry,
  usage: UsageBoard,
) -> @Sendable (InferenceRequest) async throws -> InferenceReply {
  @Dependency(\.date) var date
  @Sendable func failed(
    _ error: any Error, session: SessionID, catalog: ProviderCatalog?, inferenceStarted: Bool, ping: Bool, span: TelemetrySpan<ModelAttemptOutcome>,
  ) async throws -> Never {
    if ping {
      throw error
    }
    if error is ReplayBoundaryRequired {
      span.conclude(.handoff)
    } else if let catalog, let failure = try await recordRouteFailure(error, session: session, store: store, catalog: catalog, usage: usage, inferenceStarted: inferenceStarted), failure.reason == .upstreamOutage, let retry = failure.retryAt {
      throw ModelRouteWaiting(retryAt: retry)
    }
    throw error
  }
  @Sendable func attempt(_ request: InferenceRequest, _ span: TelemetrySpan<ModelAttemptOutcome>) async throws -> InferenceReply {
    @Dependency(\.uuid) var uuid
    let metrics = InferenceMetricsSink { metric in
      span.record(metric)
      do { try await executor.report(metric) }
      catch { Logger(label: "wuhu.inference").error("inference report failed", metadata: ["session": "\(metric.jsonLine())", "error": "\(error)"]) }
    }
    let record: SessionRecord
    let resolved: ResolvedModel
    let warmingPolicy: CacheWarmingPolicy?
    var routingCatalog: ProviderCatalog?
    do {
      record = try await store.record(request.sessionID)
      var includeGroups = false
      if case .modelGroup = record.executor { includeGroups = true }
      let selectedCatalog = try await executor.catalog(request.sessionID, includeGroups: includeGroups) { providerID, headers in
        usage.record(providerID, plan: headers["x-codex-plan-type"], windows: PlanUsage.codex(headers: headers), at: date.now)
      }
      routingCatalog = selectedCatalog
      let model: ModelSpecifier
      let route: SessionModelRoute
      switch record.executor {
      case let .kernel(specifier):
        model = specifier
        _ = try selectedCatalog.validate(specifier)
        let held = try await store.modelRoute(request.sessionID)
        let fingerprint = selectedCatalog.document.providers[specifier.provider]!.routeFingerprint
        if held == nil || held?.bindingFingerprint != fingerprint {
          let prepared = SessionModelRoute(
            group: nil,
            member: nil,
            specifier: specifier,
            bindingFingerprint: fingerprint,
            epoch: uuid().uuidString.lowercased(),
            reason: .create,
            placedAt: date.now,
            evidence: [],
          )
          route = try await store.establishInferenceModelRoute(request.sessionID, route: prepared)
        } else {
          route = held!
        }
      case let .modelGroup(id, effort):
        guard let held = try await store.modelRoute(request.sessionID) else {
          throw CatalogError.modelRouteInvalid(group: id, member: "<missing>")
        }
        route = held
        model = try selectedCatalog.validateRoute(held, group: id, effort: effort)
        if let retry = held.failure?.retryAt, retry > date.now { throw ModelRouteWaiting(retryAt: retry) }
      case .retired:
        preconditionFailure("kernel inference for \(record.executor.kind) session \(request.sessionID.rawValue)")
      }
      span.set(.modelGroup, route.group)
      resolved = try await selectedCatalog.resolve(model, session: request.sessionID, routeEpoch: request.binding?.epoch ?? route.epoch)
      warmingPolicy = selectedCatalog.document.providers[model.provider]?.models[model.model]?.cacheWarming
      if request.binding.map({ $0.identity != resolved.bindingIdentity }) == true {
        throw ReplayBoundaryRequired(binding: ReplayBinding(identity: resolved.bindingIdentity, epoch: uuid().uuidString.lowercased()))
      }
    } catch {
      await sockets.invalidate(request.sessionID)
      try await failed(error, session: request.sessionID, catalog: routingCatalog, inferenceStarted: false, ping: request.ping, span: span)
    }
    span.set(.transport, resolved.transport.rawValue)
    // The generation's prompt as stored, tool list included: an upgrade changes neither until the next generation renders, and the session is told once what changed.
    let prompt = try await executor.prompt(request.sessionID)
    let tools = try prompt.tools.map { try JSONValueDecoder().decode(Tool.self, from: $0) }
    if let changed = ToolRosterChanged(stored: tools, live: SessionToolExecutor.kernel.tools, told: request.lines) {
      span.conclude(.handoff)
      throw changed
    }
    let lease: (session: ResponsesWebSocketSession, lease: UUID)?
    if resolved.transport == .websocket {
      lease = try await sockets.acquire(session: request.sessionID, model: resolved)
    } else {
      await sockets.invalidate(request.sessionID)
      lease = nil
    }
    do {
      let inferenceExecutor = InferenceExecutor(
        session: request.sessionID,
        model: resolved,
        systemPrompt: prompt.prompt,
        opening: prompt.opening,
        tools: tools,
        trace: access.trace,
        metrics: metrics,
        webSocket: lease?.session,
        receiveQuota: { event in
          let parsed = PlanUsage.codexSocket(event)
          if !parsed.windows.isEmpty {
            usage.record(resolved.specifier.provider, plan: parsed.plan, windows: parsed.windows, at: date.now)
          }
        },
        mediaResolver: executor.mediaResolver(request.sessionID),
      )
      let completed = try await inferenceExecutor.run(
        attemptID: request.attemptID,
        lines: request.lines,
        idleTimeout: request.idleTimeout,
      )
      span.set(.finishReason, completed.metadata.stopReason.rawValue)
      if let held = try await store.modelRoute(request.sessionID), held.failure != nil {
        try await store.updateInferenceModelRouteFailure(request.sessionID, expectedEpoch: held.epoch, failure: nil)
      }
      if let lease { await sockets.release(session: request.sessionID, lease: lease.lease) }
      let warming = warmingSchedule(
        record: record, policy: warmingPolicy, lines: request.lines, images: resolved.budget.images,
        provider: resolved.specifier.provider, usage: usage, at: date.now,
      )
      return InferenceReply(message: completed.message, metadata: completed.metadata, replayBinding: ReplayBinding(identity: resolved.bindingIdentity, epoch: resolved.routeEpoch), committed: { entry in
        await inferenceExecutor.acknowledge(entry: entry, context: completed.context)
      }, warming: warming)
    } catch {
      if let lease { await sockets.invalidate(request.sessionID, lease: lease.lease) }
      if error is InferenceCancelled { throw InferenceError.cancelled }
      try await failed(error, session: request.sessionID, catalog: routingCatalog, inferenceStarted: true, ping: request.ping, span: span)
    }
  }
  return { request in try await traced(.attempt) { span in try await attempt(request, span) } }
}

/// What a reply leaves its session to warm with: an agent's policy, once the request it answered reaches the floor and the provider's five-hour window has quota left. Judged here, once; the cell judges only its own rows.
func warmingSchedule(
  record: SessionRecord, policy: CacheWarmingPolicy?, lines: [TranscriptLine], images: ImageLimits,
  provider: String, usage: UsageBoard, at now: Date,
) -> WarmingSchedule? {
  guard record.kind == .agent, let policy, lines.reachesCacheWarmingFloor(policy.floorTokens, images: images) else { return nil }
  if let used = usage.usage(provider, at: now)?.windows.first(where: { $0.name == "five_hour" })?.usedPercent, used.isFinite,
     100 - used <= policy.minimumRemainingPercent
  { return nil }
  return WarmingSchedule(intervalSeconds: policy.intervalSeconds, lifetimeSeconds: policy.lifetimeSeconds, maxPings: policy.maxPings)
}
