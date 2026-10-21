#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore

public enum SessionEvent: Codable, Sendable {
  case modelRouteEstablished(SessionModelRoute)
  case modelRouteFailureUpdated(expectedEpoch: String, failure: ModelRouteFailure?)
  case inputEnqueued(QueueInput)
  case pendingCacheWarmingDiscarded
  case transcriptAppended(items: [TranscriptItem], inputOrigin: Bool?, completing: CompactRequestClaim?)
  case portableHandoff(expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition?)
  case compacted(closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completing: CompactRequestClaim?, transition: ModelRouteTransition?)
  case interrupted, resumed
  case compactionActivity(CompactionActivity)
  case errored(String)
}

public enum CompactionActivity: Codable, Sendable {
  case active, inactive
}

public struct RegisteredSubscriptions: Codable, Sendable {
  public var ids: Set<SubscriptionID>
  public var handlers: Set<SubscriptionID>

  public init(ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) { self.ids = ids; self.handlers = handlers }
}

public enum MainReply: Codable, Sendable {
  case acknowledged
  case modelRoute(SessionModelRoute)
  case queuePosition(Int)
  case transcript(Transcript)

  public func value<Value>(_ type: Value.Type) throws -> Value {
    let value: Any = switch self {
    case .acknowledged: ()
    case let .modelRoute(value): value
    case let .queuePosition(value): value
    case let .transcript(value): value
    }
    guard let result = value as? Value else { throw MainContractError.unexpectedReply }
    return result
  }
}

public enum MainContractError: Error, Equatable {
  case unexpectedReply
}
