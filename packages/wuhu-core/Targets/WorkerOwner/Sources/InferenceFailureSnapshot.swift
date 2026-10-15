#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum Fetch.TransportFailureKind
import struct WorkerProtocol.WorkerProtocolError
import enum WuhuAI.InferenceError

struct InferenceFailureSnapshot: Codable, Sendable {
  let kind: String
  var retryAt: Date?
  var code: String?
  var message: String?
  var status: Int?
  var limit: Int?
  var reason: String?
  init(_ error: InferenceError) {
    switch error {
    case let .credentialRefreshRefused(provider): kind = "credential-refresh-refused"; code = provider
    case let .authenticationRefused(code): kind = "authentication-refused"; self.code = code
    case let .upstreamUnavailable(code): kind = "upstream-unavailable"; self.code = code
    case let .rateLimited(retryAt): kind = "rate-limited"; self.retryAt = retryAt
    case let .capacityExceeded(code, message, status): kind = "capacity-exceeded"; self.code = code; self.message = message; self.status = status
    case .contextTooLong: kind = "context-too-long"
    case let .requestTooLarge(limit): kind = "request-too-large"; self.limit = limit
    case let .requestTooLargeAfterCompaction(limit): kind = "request-too-large-after-compaction"; self.limit = limit
    case let .malformedModelMessage(message, reason): kind = "malformed-model-message"; self.message = message; self.reason = reason
    case let .invalidInput(status, body): kind = "invalid-input"; self.status = status; message = body
    case let .transient(status, body): kind = "transient"; self.status = status; message = body
    case let .transport(kind): self.kind = "transport"; code = kind.rawValue
    case let .other(status, body): kind = "other"; self.status = status; message = body
    case .cancelled: kind = "cancelled"
    }
  }

  func error() throws -> InferenceError {
    switch kind {
    case "credential-refresh-refused": if let code { return .credentialRefreshRefused(provider: code) }
    case "authentication-refused": if let code { return .authenticationRefused(code: code) }
    case "upstream-unavailable": if let code { return .upstreamUnavailable(code: code) }
    case "rate-limited": return .rateLimited(retryAt: retryAt)
    case "capacity-exceeded": if let code, let message { return .capacityExceeded(code: code, message: message, status: status) }
    case "context-too-long": return .contextTooLong
    case "request-too-large": if let limit { return .requestTooLarge(limitBytes: limit) }
    case "request-too-large-after-compaction": if let limit { return .requestTooLargeAfterCompaction(limitBytes: limit) }
    case "malformed-model-message": if let message { return .malformedModelMessage(message: message, reason: reason) }
    case "invalid-input": if let status { return .invalidInput(status: status, body: message) }
    case "transient": return .transient(status: status, body: message)
    case "transport": if let code, let kind = TransportFailureKind(rawValue: code) { return .transport(kind) }
    case "other": return .other(status: status, body: message)
    case "cancelled": return .cancelled
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid inference failure snapshot")
  }
}
