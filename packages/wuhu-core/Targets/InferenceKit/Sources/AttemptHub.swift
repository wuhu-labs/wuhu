import Foundation
import struct SessionDomain.SessionID
import Synchronization
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata
import enum WuhuAI.InferenceEvent

public enum AttemptEvent: Sendable {
  case started(attemptID: UUID)
  case delta(attemptID: UUID, event: InferenceEvent)
  case finished(attemptID: UUID, outcome: AttemptOutcome)

  public var attemptID: UUID {
    switch self {
    case let .started(id), let .delta(id, _), let .finished(id, _): id
    }
  }
}

public enum AttemptOutcome: Sendable {
  case done(AssistantMessage, AssistantMessageMetadata)
  case failed(reason: String)
}

// Memory-only per-session pub/sub for streamed inference attempts. A cold
// session is a silent topic: subscribing never materializes anything, and
// publishing to a topic with no subscribers only updates the in-flight
// snapshot used by late joiners.
public final class AttemptHub: Sendable {
  private struct Topic {
    var continuations: [UUID: AsyncStream<AttemptEvent>.Continuation] = [:]
    var inFlight: [UUID: AssistantMessage] = [:]

    var isEmpty: Bool { continuations.isEmpty && inFlight.isEmpty }
  }

  private let topics = Mutex<[SessionID: Topic]>([:])

  public init() {}

  public func publish(session: SessionID, _ event: AttemptEvent) {
    let continuations = topics.withLock { topics -> [AsyncStream<AttemptEvent>.Continuation] in
      var topic = topics[session] ?? Topic()
      switch event {
      case let .started(attemptID):
        topic.inFlight[attemptID] = AssistantMessage()
      case let .delta(attemptID, inference):
        topic.inFlight[attemptID] = inference.partialMessage
      case let .finished(attemptID, _):
        topic.inFlight[attemptID] = nil
      }
      topics[session] = topic.isEmpty ? nil : topic
      return Array(topic.continuations.values)
    }
    for continuation in continuations {
      continuation.yield(event)
    }
  }

  public func events(session: SessionID) -> AsyncStream<AttemptEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AttemptEvent>.makeStream()
    topics.withLock { topics in
      topics[session, default: Topic()].continuations[id] = continuation
    }
    continuation.onTermination = { _ in
      self.unsubscribe(session: session, id: id)
    }
    return stream
  }

  private func unsubscribe(session: SessionID, id: UUID) {
    topics.withLock { topics in
      guard var topic = topics[session] else { return }
      topic.continuations[id] = nil
      topics[session] = topic.isEmpty ? nil : topic
    }
  }

  public func inFlight(session: SessionID) -> [UUID: AssistantMessage] {
    topics.withLock { $0[session]?.inFlight ?? [:] }
  }
}

extension InferenceEvent {
  public var partialMessage: AssistantMessage {
    switch self {
    case let .start(partial),
         let .textStart(_, partial),
         let .textDelta(_, _, partial),
         let .textEnd(_, _, partial),
         let .reasoningStart(_, partial),
         let .reasoningDelta(_, _, partial),
         let .reasoningEnd(_, _, partial),
         let .toolCallStart(_, partial),
         let .toolCallDelta(_, _, partial),
         let .toolCallEnd(_, _, partial),
         let .usage(_, _, partial),
         let .done(partial, _):
      partial
    }
  }
}
