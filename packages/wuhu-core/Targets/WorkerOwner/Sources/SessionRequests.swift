#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct SessionDomain.GenerationHead
import struct SessionDomain.ModelRouteFailure
import struct SessionDomain.ModelRouteTransition
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

struct SessionIDRequest: Codable, Sendable { let id: SessionID }
struct RouteRequest: Codable, Sendable { let id: SessionID; let route: SessionModelRoute }
struct RouteFailureRequest: Codable, Sendable { let id: SessionID; let expectedEpoch: String; let failure: ModelRouteFailure? }
struct EnqueueRequest: Codable, Sendable { let id: SessionID; let input: QueueInput }
struct AppendRequest: Codable, Sendable { let id: SessionID; let items: [TranscriptItem]; let transcript: TranscriptSnapshot; let claim: String? }
struct ScopeRequest: Codable, Sendable { let id: SessionID; let toolCallID: ToolCallID }
struct ClaimRequest: Codable, Sendable { let id: SessionID; let generation: Int }
struct HandoffRequest: Codable, Sendable { let id: SessionID; let expectedGeneration: Int; let source: TranscriptSnapshot; let transcript: TranscriptSnapshot; let transition: RouteTransitionSnapshot? }
struct CompactionRequest: Codable, Sendable { let id: SessionID; let closing: ToolResultItem?; let head: GenerationHead; let kept: Range<Int>?; let claim: String?; let transition: RouteTransitionSnapshot? }
struct ErrorRequest: Codable, Sendable { let id: SessionID; let message: String }
struct CompactingRequest: Codable, Sendable { let id: SessionID; let active: Bool }
struct ArchiveRequest: Codable, Sendable { let id: SessionID; let grace: DurationSnapshot }
struct RestartRequest: Codable, Sendable { let id: SessionID; let executor: ExecutorSnapshot?; let note: String?; let modelRoute: SessionModelRoute? }
struct SubscriptionsSnapshot: Codable, Sendable {
  let ids: Set<SubscriptionID>
  let handlers: Set<SubscriptionID>
  init(_ value: (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>)) { ids = value.ids; handlers = value.handlers }
}

struct DurationSnapshot: Codable, Sendable {
  let seconds: Int64
  let attoseconds: Int64
  init(_ duration: Duration) { (seconds, attoseconds) = duration.components }
  var duration: Duration { Duration(secondsComponent: seconds, attosecondsComponent: attoseconds) }
}

func remoteHandle(_ claim: CompactRequestClaim?) throws -> String? {
  guard let claim else { return nil }
  guard let handle = claim.opaqueHandle else { throw WorkerProtocolError(.invalidMessage, message: "Remote compact completion requires an opaque claim") }
  return handle
}

struct RouteTransitionSnapshot: Codable, Sendable {
  let expectedEpoch: String
  let route: SessionModelRoute
  let transcript: TranscriptSnapshot
  init(_ value: ModelRouteTransition) {
    expectedEpoch = value.expectedEpoch
    route = value.route
    transcript = .init(value.transcript)
  }

  var value: ModelRouteTransition { .init(expectedEpoch: expectedEpoch, route: route, transcript: transcript.value) }
}
