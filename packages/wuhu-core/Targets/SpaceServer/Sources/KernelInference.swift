import Dependencies
import protocol MainHub.Main
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import Logging
import LoopCore
import ServerTelemetry
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.ReplayBinding
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import enum SpaceContract.SessionToolExecutor
import struct SpaceCore.SessionRecord
import WuhuAI

func kernelInference(
  owner: any Main,
  executor: ToolExecutor,
  access: InferenceAccess,
  sockets: ResponsesSocketRegistry,
  attempts: AttemptHub,
  usage: UsageBoard,
  committedWarming: @escaping @Sendable (SessionID, CacheWarmingPolicy) async -> Void = { _, _ in },
) -> @Sendable (InferenceRequest) async throws -> InferenceReply {
  @Dependency(\.date) var date
  @Sendable func failed(_ error: any Error, session: SessionID, catalog: ProviderCatalog?, inferenceStarted: Bool, span: TelemetrySpan<ModelAttemptOutcome>) async throws -> Never {
    if error is ReplayBoundaryRequired {
      span.conclude(.handoff)
    } else if let catalog, let failure = try await recordRouteFailure(error, session: session, owner: owner, catalog: catalog, usage: usage, inferenceStarted: inferenceStarted), failure.reason == .upstreamOutage, let retry = failure.retryAt {
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
      record = try await owner.record(request.sessionID)
      var includeGroups = false
      if case .modelGroup = record.executor { includeGroups = true }
      let selectedCatalog = try await executor.catalog(request.sessionID, includeGroups: includeGroups) { providerID, headers in
        usage.record(providerID, plan: headers["x-codex-plan-type"], windows: codexUsage(headers: headers), at: date.now)
      }
      routingCatalog = selectedCatalog
      let model: ModelSpecifier
      let route: SessionModelRoute
      switch record.executor {
      case let .kernel(specifier):
        model = specifier
        _ = try selectedCatalog.validate(specifier)
        let held = try await owner.modelRoute(request.sessionID)
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
          route = try await owner.append(request.sessionID, .modelRouteEstablished(prepared)).value(SessionModelRoute.self)
        } else {
          route = held!
        }
      case let .modelGroup(id, effort):
        guard let held = try await owner.modelRoute(request.sessionID) else {
          throw CatalogError.modelRouteInvalid(group: id, member: "<missing>")
        }
        route = held
        model = try selectedCatalog.validateRoute(held, group: id, effort: effort)
        if let retry = held.failure?.retryAt, retry > date.now { throw ModelRouteWaiting(retryAt: retry) }
      case .retired:
        preconditionFailure("kernel inference for \(record.executor.kind) session \(request.sessionID.rawValue)")
      }
      span.set(.modelGroup, route.group)
      resolved = try await selectedCatalog.resolve(model, session: request.sessionID, routeEpoch: request.transcript.replayBinding?.epoch ?? route.epoch)
      warmingPolicy = selectedCatalog.document.providers[model.provider]?.models[model.model]?.cacheWarming
      if request.transcript.requiresReplayHandoff(to: resolved.bindingIdentity) {
        throw ReplayBoundaryRequired(binding: ReplayBinding(identity: resolved.bindingIdentity, epoch: uuid().uuidString.lowercased()), budget: resolved.budget)
      }
    } catch {
      await sockets.invalidate(request.sessionID)
      try await failed(error, session: request.sessionID, catalog: routingCatalog, inferenceStarted: false, span: span)
    }
    span.set(.transport, resolved.transport.rawValue)
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
        systemPrompt: try await executor.prompt(request.sessionID).prompt,
        tools: SessionToolExecutor.kernel.tools,
        compactToolName: KernelToolset.compactToolName,
        hub: attempts,
        trace: access.trace,
        metrics: metrics,
        webSocket: lease?.session,
        receiveQuota: { event in
          let parsed = codexSocketUsage(event)
          if !parsed.windows.isEmpty {
            usage.record(resolved.specifier.provider, plan: parsed.plan, windows: parsed.windows, at: date.now)
          }
        },
        mediaResolver: { executor.mediaResolver(request.sessionID, limits: $0) },
      )
      let completed = try await inferenceExecutor.run(
        attemptID: request.attemptID,
        transcript: request.transcript,
        mode: request.mode == .forcedCompact ? .forcedCompact : .normal,
        idleTimeout: request.idleTimeout,
      )
      span.set(.finishReason, completed.metadata.stopReason.rawValue)
      if let held = try await owner.modelRoute(request.sessionID), held.failure != nil {
        try await owner.append(request.sessionID, .modelRouteFailureUpdated(expectedEpoch: held.epoch, failure: nil)).value(Void.self)
      }
      if let lease { await sockets.release(session: request.sessionID, lease: lease.lease) }
      return InferenceReply(message: completed.message, metadata: completed.metadata, replayBinding: ReplayBinding(identity: resolved.bindingIdentity, epoch: resolved.routeEpoch), committed: { entry, transcript in
        if record.kind == .agent, let warmingPolicy { await committedWarming(request.sessionID, warmingPolicy) }
        await inferenceExecutor.acknowledge(entry: entry, transcript: transcript)
      })
    } catch {
      if let lease { await sockets.invalidate(request.sessionID, lease: lease.lease) }
      if error is InferenceCancelled { throw InferenceError.cancelled }
      try await failed(error, session: request.sessionID, catalog: routingCatalog, inferenceStarted: true, span: span)
    }
  }
  return { request in try await traced(.attempt) { span in try await attempt(request, span) } }
}
