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

  /// Who an attempt is billed to.
  public enum Payer: Hashable, Sendable {
    case session(SessionID)
    /// A group observer's handler, in one firing.
    case observer(group: String, firing: String)
  }

  /// The attempt, minted where the inference ran: a report that reaches the
  /// server twice records once.
  public var id: String
  public var timestamp: Date
  public var payer: Payer
  public var provider: String
  public var model: String
  public var servedModel: String?
  public var effort: String
  public var outcome: Outcome
  public var errorKind: String?
  public var status: Int?
  public var ttftMs: Int64?
  public var durationMs: Int64
  public var usage: Usage?

  public init(
    id: String = UUID().uuidString.lowercased(),
    timestamp: Date,
    payer: Payer,
    provider: String,
    model: String,
    servedModel: String? = nil,
    effort: String,
    outcome: Outcome,
    errorKind: String? = nil,
    status: Int? = nil,
    ttftMs: Int64? = nil,
    durationMs: Int64,
    usage: Usage? = nil,
  ) {
    self.id = id
    self.timestamp = timestamp
    self.payer = payer
    self.provider = provider
    self.model = model
    self.servedModel = servedModel
    self.effort = effort
    self.outcome = outcome
    self.errorKind = errorKind
    self.status = status
    self.ttftMs = ttftMs
    self.durationMs = durationMs
    self.usage = usage
  }

  public var session: SessionID? {
    if case let .session(session) = payer { session } else { nil }
  }

  public func jsonLine() -> String {
    var object: OrderedDictionary<String, JSONValue> = [:]
    object["ts"] = .string(timestamp.ISO8601Format())
    switch payer {
    case let .session(session): object["session"] = .string(session.rawValue)
    case let .observer(group, firing): object["group"] = .string(group); object["firing"] = .string(firing)
    }
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
        "reasoning": .integer(usage.reasoningTokens ?? 0),
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
    case .streamCut:
      return (.networkError, "streamCut", nil)
    case .upstreamUnavailable:
      return (.httpError, "upstreamUnavailable", nil)
    case .oidcSigningFailed:
      return (.httpError, "oidcSigningFailed", nil)
    case .credentialRefreshRefused:
      return (.httpError, "credentialRefreshRefused", 401)
    case .authenticationRefused:
      return (.httpError, "authenticationRefused", 401)
    case .rateLimited:
      return (.httpError, "rateLimited", 429)
    case let .capacityExceeded(code, _, status):
      return (.httpError, code, status)
    case .malformedModelMessage:
      return (.httpError, "malformedModelMessage", nil)
    case .requestTooLarge:
      return (.httpError, "requestTooLarge", 413)
    case .requestTooLargeAfterCompaction:
      return (.httpError, "requestTooLargeAfterCompaction", 413)
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
