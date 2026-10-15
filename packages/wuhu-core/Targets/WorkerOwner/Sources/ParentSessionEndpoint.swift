#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct SessionDomain.GenerationHead
import enum SessionDomain.QueueInput
import struct SessionDomain.ScopeContext
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SessionDomain.SubscriptionID
import struct SessionDomain.ToolCallID
import struct SessionDomain.ToolResultItem
import struct SessionDomain.Transcript
import enum SessionDomain.TranscriptItem
import struct SpaceCore.CompactRequestClaim
import struct SpaceCore.QueueDrain
import enum SpaceCore.SessionCommand
import protocol SpaceCore.SessionExecutionOwnerClient
import struct SpaceCore.SessionHydration
import struct SpaceCore.SessionRecord
import struct SpaceCore.SessionRestart
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

struct ParentSessionEndpoint: Sendable {
  let owner: any SessionExecutionOwnerClient
  private let claims = CompactClaims()
  init(owner: any SessionExecutionOwnerClient) { self.owner = owner }

  func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation { case "session.record":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(RecordSnapshot(try await owner.record(request.id)))
      case "session.model-route":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(try await owner.modelRoute(request.id))
      case "session.establish-model-route":
        let request = try ownerDecode(RouteRequest.self, call.payload)
        return try ownerEncode(try await owner.establishModelRoute(request.id, route: request.route))
      case "session.update-model-route-failure":
        let request = try ownerDecode(RouteFailureRequest.self, call.payload)
        try await owner.updateModelRouteFailure(request.id, expectedEpoch: request.expectedEpoch, failure: request.failure)
        return .bool(true)
      case "session.hydrate":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(HydrationSnapshot(try await owner.hydrate(request.id)))
      case "session.enqueue":
        let request = try ownerDecode(EnqueueRequest.self, call.payload)
        return try ownerEncode(try await owner.enqueue(request.id, input: request.input))
      case "session.drain-queue":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(DrainSnapshot(try await owner.drainQueue(request.id)))
      case "session.discard-pending-cache-warming":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(TranscriptSnapshot(await owner.discardPendingCacheWarming(request.id)))
      case "session.append":
        let request = try ownerDecode(AppendRequest.self, call.payload)
        guard request.claim == nil || !request.items.isEmpty else { throw WorkerProtocolError(.invalidMessage, message: "Compact completion requires appended items") }
        try await owner.append(request.id, items: request.items, transcript: request.transcript.value, completingCompactRequest: claims.resolve(request.claim, session: request.id))
        await claims.complete(request.claim)
        return .bool(true)
      case "session.scope-context":
        let request = try ownerDecode(ScopeRequest.self, call.payload)
        return try ownerEncode(try await owner.scopeContext(request.id, toolCallID: request.toolCallID))
      case "session.queue-head":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(try await owner.queueHead(request.id))
      case "session.pending-command":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(try await owner.pendingCommand(request.id).map(CommandSnapshot.init))
      case "session.claim-compact-request":
        let request = try ownerDecode(ClaimRequest.self, call.payload)
        return try ownerEncode(try await claims.issue(session: request.id, generation: request.generation, owner: owner))
      case "session.write-portable-handoff":
        let request = try ownerDecode(HandoffRequest.self, call.payload)
        return try ownerEncode(TranscriptSnapshot(await owner.writePortableHandoff(request.id, expectedGeneration: request.expectedGeneration, source: request.source.value, transcript: request.transcript.value, transition: request.transition?.value)))
      case "session.write-compaction":
        let request = try ownerDecode(CompactionRequest.self, call.payload)
        let transcript = try await owner.writeCompaction(request.id, closing: request.closing, head: request.head, kept: request.kept, completingCompactRequest: claims.resolve(request.claim, session: request.id), transition: request.transition?.value)
        await claims.complete(request.claim)
        return try ownerEncode(TranscriptSnapshot(transcript))
      case "session.mark-interrupted":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await owner.markInterrupted(request.id)
        return .bool(true)
      case "session.mark-resumed":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await owner.markResumed(request.id)
        return .bool(true)
      case "session.mark-errored":
        let request = try ownerDecode(ErrorRequest.self, call.payload)
        try await owner.markErrored(request.id, message: request.message)
        return .bool(true)
      case "session.archive":
        let request = try ownerDecode(ArchiveRequest.self, call.payload)
        return try ownerEncode(try await owner.archive(request.id, grace: request.grace.duration))
      case "session.unarchive":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await owner.unarchive(request.id)
        return .bool(true)
      case "session.restart":
        let request = try ownerDecode(RestartRequest.self, call.payload)
        return try ownerEncode(RestartSnapshot(try await owner.restart(request.id, executor: request.executor?.executor(), note: request.note, modelRoute: request.modelRoute)))
      case "session.registered-subscriptions":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(SubscriptionsSnapshot(try await owner.registeredSubscriptions(request.id)))
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent session operation")
      }
    }
  }
}
