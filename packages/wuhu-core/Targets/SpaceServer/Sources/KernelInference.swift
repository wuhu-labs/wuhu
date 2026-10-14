import Dependencies
import ExecutionOwner
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import LoopCore
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.ReplayBinding
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import enum SpaceContract.SessionToolExecutor
import struct SpaceCore.SessionRecord
import WuhuAI

func kernelInference(
  owner: any ExecutionOwnerClient,
  catalog: @escaping @Sendable () async throws -> ProviderCatalog,
  groupCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
  sockets: ResponsesSocketRegistry,
  attempts: AttemptHub,
  usage: UsageBoard,
  makeBindingEpoch: @escaping @Sendable () -> UUID = { UUID() },
  committedWarming: @escaping @Sendable (SessionID, CacheWarmingPolicy) async -> Void = { _, _ in },
) -> @Sendable (InferenceRequest) async throws -> InferenceReply {
  @Dependency(\.date) var date
  let metrics = InferenceMetricsSink { await owner.recordMetric($0) }
  return { request in
    let record: SessionRecord
    let resolved: ResolvedModel
    let warmingPolicy: CacheWarmingPolicy?
    do {
      record = try await owner.record(request.sessionID)
      let selectedCatalog: ProviderCatalog
      if case .modelGroup = record.executor, let groupCatalog {
        selectedCatalog = try await groupCatalog()
      } else {
        selectedCatalog = try await catalog()
      }
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
            epoch: makeBindingEpoch().uuidString.lowercased(),
            reason: .create,
            placedAt: date.now,
            evidence: [],
          )
          route = try await owner.establishModelRoute(request.sessionID, route: prepared)
        } else {
          route = held!
        }
      case let .modelGroup(id, effort):
        guard let held = try await owner.modelRoute(request.sessionID) else {
          throw CatalogError.modelRouteInvalid(group: id, member: "<missing>")
        }
        route = held
        model = try selectedCatalog.validateRoute(held, group: id, effort: effort)
        _ = try await selectedCatalog.validateGroupReadiness(id, effort: effort)
      case .claudeCode, .contractor:
        preconditionFailure("kernel inference for \(record.executor.kind) session \(request.sessionID.rawValue)")
      }
      resolved = try await selectedCatalog.resolve(model, session: request.sessionID, routeEpoch: request.transcript.replayBinding?.epoch ?? route.epoch)
      warmingPolicy = selectedCatalog.document.providers[model.provider]?.models[model.model]?.cacheWarming
      if request.transcript.requiresReplayHandoff(to: resolved.bindingIdentity) {
        @Dependency(\.uuid) var uuid
        throw ReplayBoundaryRequired(binding: ReplayBinding(identity: resolved.bindingIdentity, epoch: uuid().uuidString.lowercased()), budget: resolved.budget)
      }
    } catch {
      await sockets.invalidate(request.sessionID)
      throw error
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
        systemPrompt: try await systemPrompt(owner: owner, record: record),
        tools: SessionToolExecutor.kernel.tools,
        compactToolName: KernelToolset.compactToolName,
        hub: attempts,
        trace: owner.tracesAttempts ? AttemptTraceClient { try await owner.openAttemptTrace($0) } : nil,
        metrics: metrics,
        webSocket: lease?.session,
        receiveQuota: { event in
          let parsed = codexSocketUsage(event)
          if !parsed.windows.isEmpty { usage.record(resolved.specifier.provider, plan: parsed.plan, windows: parsed.windows, at: date.now) }
        },
        mediaResolver: { [group = record.group] in OwnerMediaResolver(owner: owner, limits: $0, group: group) },
      )
      let completed = try await inferenceExecutor.run(
        attemptID: request.attemptID,
        transcript: request.transcript,
        mode: request.mode == .forcedCompact ? .forcedCompact : .normal,
        idleTimeout: request.idleTimeout,
        handles: try await owner.handlesByPrincipal(),
        devices: try await owner.deviceNames(),
      )
      if let lease { await sockets.release(session: request.sessionID, lease: lease.lease) }
      return InferenceReply(message: completed.message, metadata: completed.metadata, replayBinding: ReplayBinding(identity: resolved.bindingIdentity, epoch: resolved.routeEpoch), committed: { entry, transcript in
        if record.kind == .agent, let warmingPolicy { await committedWarming(request.sessionID, warmingPolicy) }
        await inferenceExecutor.acknowledge(entry: entry, transcript: transcript, handles: (try? await owner.handlesByPrincipal()) ?? [:], devices: (try? await owner.deviceNames()) ?? [:])
      })
    } catch {
      if let lease { await sockets.invalidate(request.sessionID, lease: lease.lease) }
      if error is InferenceCancelled { throw InferenceError.cancelled }
      throw error
    }
  }
}
