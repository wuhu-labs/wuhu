#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore

public struct SessionAccess: Sendable {
  nonisolated public var beforeAppend: @Sendable (SessionID, SessionEvent) async throws -> Void = { _, _ in }
  nonisolated public var beforeHydrate: @Sendable (SessionID) async throws -> Void = { _ in }
  nonisolated public var beforeQueueHead: @Sendable (SessionID) async throws -> Void = { _ in }
  nonisolated public var afterPendingCommand: @Sendable (SessionID) async throws -> Void = { _ in }
  nonisolated public var beforeClaim: @Sendable (SessionID) async throws -> Void = { _ in }
  nonisolated public var afterClaim: @Sendable (SessionID) async throws -> Void = { _ in }
  public init() {}
}

extension Hub {
  nonisolated public func append(_ id: SessionID, _ event: SessionEvent) async throws -> MainReply {
    try await sessionAccess.beforeAppend(id, event)
    switch event {
    case .modelRouteEstablished(let route): return try await .modelRoute(store.establishModelRoute(id, route: route))
    case let .modelRouteFailureUpdated(epoch, failure): try await store.updateModelRouteFailure(id, expectedEpoch: epoch, failure: failure)
    case .inputEnqueued(let input): return try await .queuePosition(store.enqueue(id, input: input))
    case .pendingCacheWarmingDiscarded: return try await .transcript(store.discardPendingCacheWarming(id))
    case .compactRequestAlreadyCompacted: _ = try await store.takeCommand(id)
    case let .transcriptAppended(items, inputOrigin, claim): try await store.append(id, items: items, inputOrigin: inputOrigin, completingCompactRequest: claim)
    case let .portableHandoff(generation, source, transcript):
      return try await .transcript(store.writePortableHandoff(id, expectedGeneration: generation, source: source, transcript: transcript))
    case let .compacted(closing, head, kept, claim, transition):
      return try await .transcript(store.writeCompaction(id, closing: closing, head: head, kept: kept, completingCompactRequest: claim, transition: transition))
    case .interrupted: try await store.markInterrupted(id)
    case .resumed: try await store.markResumed(id)
    case .compactionActivity(let activity): try await store.markCompacting(id, active: activity == .active)
    case .errored(let message): try await store.markErrored(id, message: message)
    }
    return .acknowledged
  }

  nonisolated public func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? { try await store.modelRoute(id) }
  nonisolated public func record(_ id: SessionID) async throws -> SessionRecord { try await store.record(id) }
  nonisolated public func hydrate(_ id: SessionID) async throws -> SessionHydration {
    try await sessionAccess.beforeHydrate(id)
    return try await store.hydrateForExecution(id)
  }

  nonisolated public func queueHead(_ id: SessionID) async throws -> Int {
    try await sessionAccess.beforeQueueHead(id)
    return try await store.queueHead(id)
  }

  nonisolated public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    let command = try await store.pendingCommand(id)
    try await sessionAccess.afterPendingCommand(id)
    return command
  }

  nonisolated public func registeredSubscriptions(_ id: SessionID) async throws -> RegisteredSubscriptions {
    let registered = try await store.registeredSubscriptions(id)
    return .init(ids: registered.ids, handlers: registered.handlers)
  }

  nonisolated public func drainQueue(_ id: SessionID) async throws -> QueueDrain { try await store.drainQueue(id) }
  nonisolated public func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    try await sessionAccess.beforeClaim(id)
    let claim = try await store.claimCompactRequest(id, generation: generation)
    try await sessionAccess.afterClaim(id)
    return claim
  }
}

extension Hub {
  nonisolated public func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error> {
    let snapshots = store.observePendingArrivals(session)
    return AsyncThrowingStream { continuation in
      let forward = Task {
        do {
          for try await pending in snapshots { continuation.yield(pending) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in forward.cancel() }
    }
  }

  nonisolated public func owedExecs(_ session: SessionID) async throws -> [ExecRecord] { try await space.owedExecs(caller: session.rawValue) }
}
