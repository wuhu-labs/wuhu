import enum Fetch.TransportFailureKind
import Foundation
import JSONValue
import OrderedCollections
import struct SessionDomain.SessionID
import enum WuhuAI.InferenceError
import struct WuhuAI.Usage

public struct InferenceMetric: Sendable, Equatable {
  public enum Outcome: String, Sendable, Equatable {
    case ok
    case networkError
    case httpError
    case timeout
    case cancelled
  }

  public var timestamp: Date
  public var session: SessionID
  public var provider: String
  public var model: String
  public var effort: String
  public var outcome: Outcome
  public var errorKind: String?
  public var status: Int?
  public var ttftMs: Int64?
  public var durationMs: Int64
  public var usage: Usage?

  public init(
    timestamp: Date,
    session: SessionID,
    provider: String,
    model: String,
    effort: String,
    outcome: Outcome,
    errorKind: String? = nil,
    status: Int? = nil,
    ttftMs: Int64? = nil,
    durationMs: Int64,
    usage: Usage? = nil,
  ) {
    self.timestamp = timestamp
    self.session = session
    self.provider = provider
    self.model = model
    self.effort = effort
    self.outcome = outcome
    self.errorKind = errorKind
    self.status = status
    self.ttftMs = ttftMs
    self.durationMs = durationMs
    self.usage = usage
  }

  public func jsonLine() -> String {
    var object: OrderedDictionary<String, JSONValue> = [:]
    object["ts"] = .string(timestamp.ISO8601Format())
    object["session"] = .string(session.rawValue)
    object["provider"] = .string(provider)
    object["model"] = .string(model)
    object["effort"] = .string(effort)
    object["outcome"] = .string(outcome.rawValue)
    if let errorKind { object["error"] = .string(errorKind) }
    if let status { object["status"] = .integer(status) }
    if let ttftMs { object["ttft_ms"] = .integer(Int(ttftMs)) }
    object["duration_ms"] = .integer(Int(durationMs))
    if let usage {
      object["tokens"] = .object([
        "in": .integer(usage.inputTokens),
        "out": .integer(usage.outputTokens),
        "cache_read": .integer(usage.cacheReadTokens),
        "cache_write": .integer(usage.cacheWriteTokens),
        "reasoning": .integer(usage.reasoningTokens),
        "total": .integer(usage.totalTokens),
      ])
    }
    return JSONValue.object(object).jsonString() + "\n"
  }
}

extension InferenceMetric {
  public static func classify(_ error: InferenceError?) -> (outcome: Outcome, kind: String?, status: Int?) {
    guard let error else { return (.ok, nil, nil) }
    switch error {
    case .cancelled:
      return (.cancelled, nil, nil)
    case .rateLimited:
      return (.httpError, "rateLimited", 429)
    case .contextTooLong:
      return (.httpError, "contextTooLong", 413)
    case let .invalidInput(status, _):
      return (.httpError, "invalidInput", status)
    case let .transport(kind):
      return (kind.isTimeout ? .timeout : .networkError, kind.rawValue, nil)
    case let .transient(status, body):
      if let status { return (.httpError, "serverError", status) }
      return (.networkError, body.map { clipped($0) } ?? "transport", nil)
    case let .other(status, _):
      if let status { return (.httpError, "other", status) }
      return (.networkError, "other", nil)
    }
  }
}

private func clipped(_ text: String, to limit: Int = 80) -> String {
  text.count <= limit ? text : String(text.prefix(limit)) + "…"
}

public struct InferenceMetricsSink: Sendable {
  public var record: @Sendable (InferenceMetric) async -> Void

  public init(record: @escaping @Sendable (InferenceMetric) async -> Void) {
    self.record = record
  }

  public static let noop: InferenceMetricsSink = InferenceMetricsSink { _ in }
}
