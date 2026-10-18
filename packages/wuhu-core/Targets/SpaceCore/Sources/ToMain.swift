#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

public protocol MainClient: Sendable {
  func send(_ message: ToMain) async throws -> MainReply
}

public enum ToMain: Codable, Sendable {
  case append(SessionID, SessionEvent)
  case read(SessionID, SessionRead)
  case effect(SessionID, SessionEffect)
}

public enum SessionEvent: Codable, Sendable {
  case modelRouteEstablished(SessionModelRoute)
  case modelRouteFailureUpdated(expectedEpoch: String, failure: ModelRouteFailure?)
  case inputEnqueued(QueueInput)
  case pendingCacheWarmingDiscarded
  case transcriptAppended(items: [TranscriptItem], transcript: Transcript, completing: CompactRequestClaim?)
  case portableHandoff(expectedGeneration: Int, source: Transcript, transcript: Transcript, transition: ModelRouteTransition?)
  case compacted(closing: ToolResultItem?, head: GenerationHead, kept: Range<Int>?, completing: CompactRequestClaim?, transition: ModelRouteTransition?)
  case interrupted, resumed
  case compactionActivity(CompactionActivity)
  case errored(String)
  case archived(grace: Duration)
  case unarchived
  case restarted(executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?)
}

public enum CompactionActivity: Codable, Sendable {
  case active, inactive
}

public enum SessionRead: Codable, Sendable {
  case modelRoute, record, hydration, queueHead, pendingCommand, registeredSubscriptions
  case scopeContext(ToolCallID)
}

public enum SessionEffect: Codable, Sendable {
  case drainQueue
  case claimCompactRequest(generation: Int)
}

public struct RegisteredSubscriptions: Codable, Sendable {
  public var ids: Set<SubscriptionID>
  public var handlers: Set<SubscriptionID>

  public init(ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) { self.ids = ids; self.handlers = handlers }
}

public enum MainReply: Codable, Sendable {
  case acknowledged
  case modelRoute(SessionModelRoute?)
  case record(SessionRecord)
  case hydration(SessionHydration)
  case queuePosition(Int)
  case transcript(Transcript)
  case scopeContext(ScopeContext?)
  case command(SessionCommand?)
  case subscriptions(RegisteredSubscriptions)
  case queueDrain(QueueDrain)
  case compactClaim(CompactRequestClaim?)
  case archiveDeadline(Date)
  case restart(SessionRestart)

  public func value<Value>(_ type: Value.Type) throws -> Value {
    let value: Any = switch self {
    case .acknowledged: ()
    case let .modelRoute(value): value as Any
    case let .record(value): value
    case let .hydration(value): value
    case let .queuePosition(value): value
    case let .transcript(value): value
    case let .scopeContext(value): value as Any
    case let .command(value): value as Any
    case let .subscriptions(value): value
    case let .queueDrain(value): value
    case let .compactClaim(value): value as Any
    case let .archiveDeadline(value): value
    case let .restart(value): value
    }
    guard let result = value as? Value else { throw MainContractError.unexpectedReply }
    return result
  }
}

public enum MainContractError: Error, Equatable {
  case unexpectedReply
}

public struct InProcessMainClient: MainClient {
  private let handle: @Sendable (ToMain) async throws -> MainReply

  public init(handle: @escaping @Sendable (ToMain) async throws -> MainReply) {
    self.handle = handle
  }

  public init(sessions: SessionStore) {
    self.init { message in
      switch message {
      case let .read(id, query):
        switch query {
        case .modelRoute: return try await .modelRoute(sessions.modelRoute(id))
        case .record: return try await .record(sessions.record(id))
        case .hydration: return try await .hydration(sessions.hydrate(id))
        case .queueHead: return try await .queuePosition(sessions.queueHead(id))
        case .pendingCommand: return try await .command(sessions.pendingCommand(id))
        case .scopeContext(let call): return try await .scopeContext(sessions.scopeContext(id, toolCallID: call))
        case .registeredSubscriptions:
          let registered = try await sessions.registeredSubscriptions(id)
          return .subscriptions(.init(ids: registered.ids, handlers: registered.handlers))
        }
      case let .effect(id, effect):
        switch effect {
        case .drainQueue: return try await .queueDrain(sessions.drainQueue(id))
        case .claimCompactRequest(let generation): return try await .compactClaim(sessions.claimCompactRequest(id, generation: generation))
        }
      case let .append(id, event):
        switch event {
        case .modelRouteEstablished(let route): return try await .modelRoute(sessions.establishModelRoute(id, route: route))
        case let .modelRouteFailureUpdated(epoch, failure): try await sessions.updateModelRouteFailure(id, expectedEpoch: epoch, failure: failure)
        case .inputEnqueued(let input): return try await .queuePosition(sessions.enqueue(id, input: input))
        case .pendingCacheWarmingDiscarded: return try await .transcript(sessions.discardPendingCacheWarming(id))
        case let .transcriptAppended(items, transcript, claim): try await sessions.append(id, items: items, transcript: transcript, completingCompactRequest: claim)
        case let .portableHandoff(generation, source, transcript, transition):
          return try await .transcript(sessions.writePortableHandoff(id, expectedGeneration: generation, source: source, transcript: transcript, transition: transition))
        case let .compacted(closing, head, kept, claim, transition):
          return try await .transcript(sessions.writeCompaction(id, closing: closing, head: head, kept: kept, completingCompactRequest: claim, transition: transition))
        case .interrupted: try await sessions.markInterrupted(id)
        case .resumed: try await sessions.markResumed(id)
        case .compactionActivity(let activity): try await sessions.markCompacting(id, active: activity == .active)
        case .errored(let message): try await sessions.markErrored(id, message: message)
        case .archived(let grace): return try await .archiveDeadline(sessions.archive(id, grace: grace))
        case .unarchived: try await sessions.unarchive(id)
        case let .restarted(executor, note, route): return try await .restart(sessions.restart(id, executor: executor, note: note, modelRoute: route))
        }
        return .acknowledged
      }
    }
  }

  public func send(_ message: ToMain) async throws -> MainReply {
    let request = try JSONDecoder().decode(ToMain.self, from: JSONEncoder().encode(message))
    let reply = try await handle(request)
    return try JSONDecoder().decode(MainReply.self, from: JSONEncoder().encode(reply))
  }
}
