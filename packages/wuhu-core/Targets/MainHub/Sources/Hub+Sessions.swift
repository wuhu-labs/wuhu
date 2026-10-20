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
    case let .transcriptAppended(items, transcript, claim): try await store.append(id, items: items, transcript: transcript, completingCompactRequest: claim)
    case let .portableHandoff(generation, source, transcript, transition):
      return try await .transcript(store.writePortableHandoff(id, expectedGeneration: generation, source: source, transcript: transcript, transition: transition))
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
