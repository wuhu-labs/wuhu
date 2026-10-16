#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.AttemptEvent
import enum InferenceKit.AttemptOutcome
import struct SessionDomain.SessionID
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata
import enum WuhuAI.InferenceEvent
import struct WuhuAI.ToolCall
import struct WuhuAI.Usage

struct AttemptPublication: Codable, Sendable {
  let session: SessionID
  let event: AttemptSnapshot
}

enum AttemptUnknownOutcome: String, Codable, Sendable { case handoffFenceExpired }

enum AttemptSnapshot: Codable, Sendable {
  case started(UUID)
  case delta(UUID, InferenceSnapshot)
  case done(UUID, AssistantMessage, AssistantMessageMetadata)
  case failed(UUID, String)
  case unknown(UUID, AttemptUnknownOutcome)
  init(_ event: AttemptEvent) {
    switch event {
    case let .started(id): self = .started(id)
    case let .delta(id, event): self = .delta(id, .init(event))
    case let .finished(id, .done(message, metadata)): self = .done(id, message, metadata)
    case let .finished(id, .failed(reason)): self = .failed(id, reason)
    }
  }

  var event: AttemptEvent {
    switch self {
    case let .started(id): .started(attemptID: id)
    case let .delta(id, event): .delta(attemptID: id, event: event.event)
    case let .done(id, message, metadata): .finished(attemptID: id, outcome: .done(message, metadata))
    case let .failed(id, reason): .finished(attemptID: id, outcome: .failed(reason: reason))
    case let .unknown(id, .handoffFenceExpired): .finished(attemptID: id, outcome: .failed(reason: "unknownOutcome: parent execution handoff fence expired"))
    }
  }
}

enum InferenceSnapshot: Codable, Sendable {
  case start(AssistantMessage)
  case textStart(Int, AssistantMessage)
  case textDelta(Int, String, AssistantMessage)
  case textEnd(Int, String, AssistantMessage)
  case reasoningStart(Int, AssistantMessage)
  case reasoningDelta(Int, String, AssistantMessage)
  case reasoningEnd(Int, String, AssistantMessage)
  case toolCallStart(Int, AssistantMessage)
  case toolCallDelta(Int, String, AssistantMessage)
  case toolCallEnd(Int, ToolCall, AssistantMessage)
  case usage(Usage, String?, AssistantMessage)
  case done(AssistantMessage, AssistantMessageMetadata)
  init(_ event: InferenceEvent) {
    switch event {
    case let .start(a): self = .start(a)
    case let .textStart(a, b): self = .textStart(a, b)
    case let .textDelta(a, b, c): self = .textDelta(a, b, c)
    case let .textEnd(a, b, c): self = .textEnd(a, b, c)
    case let .reasoningStart(a, b): self = .reasoningStart(a, b)
    case let .reasoningDelta(a, b, c): self = .reasoningDelta(a, b, c)
    case let .reasoningEnd(a, b, c): self = .reasoningEnd(a, b, c)
    case let .toolCallStart(a, b): self = .toolCallStart(a, b)
    case let .toolCallDelta(a, b, c): self = .toolCallDelta(a, b, c)
    case let .toolCallEnd(a, b, c): self = .toolCallEnd(a, b, c)
    case let .usage(a, b, c): self = .usage(a, b, c)
    case let .done(a, b): self = .done(a, b)
    }
  }

  var event: InferenceEvent {
    switch self {
    case let .start(a): .start(a)
    case let .textStart(a, b): .textStart(contentIndex: a, partial: b)
    case let .textDelta(a, b, c): .textDelta(contentIndex: a, delta: b, partial: c)
    case let .textEnd(a, b, c): .textEnd(contentIndex: a, text: b, partial: c)
    case let .reasoningStart(a, b): .reasoningStart(contentIndex: a, partial: b)
    case let .reasoningDelta(a, b, c): .reasoningDelta(contentIndex: a, delta: b, partial: c)
    case let .reasoningEnd(a, b, c): .reasoningEnd(contentIndex: a, text: b, partial: c)
    case let .toolCallStart(a, b): .toolCallStart(contentIndex: a, partial: b)
    case let .toolCallDelta(a, b, c): .toolCallDelta(contentIndex: a, delta: b, partial: c)
    case let .toolCallEnd(a, b, c): .toolCallEnd(contentIndex: a, toolCall: b, partial: c)
    case let .usage(a, b, c): .usage(a, servedModel: b, partial: c)
    case let .done(a, b): .done(a, b)
    }
  }
}
