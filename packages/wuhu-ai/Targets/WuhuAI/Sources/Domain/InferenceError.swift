import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes

// MARK: - InferenceError

/// The bounded failure surface for model inference.
public enum InferenceError: Error, Sendable, Equatable {
  case rateLimited(retryAt: Date?)
  case contextTooLong
  case invalidInput(status: Int, body: String?)
  case transient(status: Int?, body: String?)
  case transport(TransportFailureKind)
  case other(status: Int?, body: String?)
  case cancelled
}

// MARK: - Classification

extension InferenceError {
  static func classify(
    status: Int,
    headers: Headers,
    body: String?,
  ) -> InferenceError {
    switch status {
    case 429:
      .rateLimited(retryAt: parseRetryAfter(headers))

    case 413:
      .contextTooLong

    case 400 ..< 500:
      if bodyIndicatesContextOverflow(body) {
        .contextTooLong
      } else {
        .invalidInput(status: status, body: body)
      }

    case 500 ..< 600:
      .transient(status: status, body: body)

    default:
      .other(status: status, body: body)
    }
  }

  static func parseRetryAfter(_ headers: Headers) -> Date? {
    guard let header = headers[.retryAfter] else { return nil }
    let raw = header[...].trimmedWhitespace
    guard !raw.isEmpty else { return nil }

    if let seconds = TimeInterval(raw) {
      return Date().addingTimeInterval(seconds)
    }

    return parseHTTPDate(raw)
  }

  static func bodyIndicatesContextOverflow(_ body: String?) -> Bool {
    guard let body else { return false }
    let haystack = body.lowercased()
    let needles = [
      "context_length_exceeded",
      "context length",
      "context window",
      "maximum context",
      "prompt is too long",
      "too many tokens",
      "exceeds the maximum number of tokens",
      "input token count",
      "reduce the length",
    ]
    return needles.contains { haystack.firstRange(of: $0) != nil }
  }
}

// MARK: - Normalization

extension InferenceError {
  public static func normalize(_ error: any Error) -> InferenceError {
    if let inferenceError = error as? InferenceError {
      return inferenceError
    }

    if error is CancellationError {
      return .cancelled
    }

    if let fetchError = error as? FetchError, case let .transportFailure(kind) = fetchError {
      return .transport(kind)
    }

    if let providerStreamError = error as? ProviderStreamError {
      return providerStreamError.asInferenceError()
    }

    if let responsesStreamError = error as? ResponsesStreamError {
      return responsesStreamError.asInferenceError()
    }

    if isTransportError(error) {
      return .transient(status: nil, body: nil)
    }

    return .other(status: nil, body: diagnosticBody(for: error))
  }

  private static func isTransportError(_ error: any Error) -> Bool {
    if let fetchError = error as? FetchError {
      switch fetchError {
      case .invalidTextEncoding, .bodyAlreadyConsumed, .bodyLimitExceeded, .transportFailure:
        return true
      case .unimplemented, .unexpectedStatus:
        return false
      }
    }
    #if canImport(FoundationEssentials)
      return false
    #else
      if error is URLError { return true }
      let nsError = error as NSError
      return nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
    #endif
  }

  private static func diagnosticBody(for error: any Error) -> String? {
    let description = String(describing: error)
    return description.isEmpty ? nil : description
  }
}

// MARK: - ProviderStreamError

struct ProviderStreamError: Error, Sendable, Equatable {
  var type: String?
  var message: String?

  init(type: String?, message: String?) {
    self.type = type
    self.message = message
  }

  static func invalidStream(_ message: String) -> Self {
    Self(type: "invalid_stream", message: message)
  }

  func asInferenceError() -> InferenceError {
    switch type {
    case "rate_limit_error":
      .rateLimited(retryAt: nil)

    case "overloaded_error", "api_error", "invalid_stream":
      .transient(status: nil, body: diagnosticBody)

    case "invalid_request_error":
      if InferenceError.bodyIndicatesContextOverflow(message) {
        .contextTooLong
      } else {
        .invalidInput(status: 400, body: message)
      }

    default:
      if InferenceError.bodyIndicatesContextOverflow(message) {
        .contextTooLong
      } else {
        .other(status: nil, body: diagnosticBody)
      }
    }
  }

  private var diagnosticBody: String? {
    switch (type, message) {
    case let (.some(type), .some(message)):
      "\(type): \(message)"
    case let (.some(type), nil):
      type
    case let (nil, .some(message)):
      message
    case (nil, nil):
      nil
    }
  }
}

extension ResponsesStreamError {
  func asInferenceError() -> InferenceError {
    switch self {
    case let .failed(status):
      .transient(status: nil, body: status)
    case .cancelled:
      .cancelled
    }
  }
}

// MARK: - HTTP Date

// RFC 7231 IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT"); day/month names are
// protocol constants, not locale-formatted text, so this parses without ICU.
private let httpMonths = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]
private let httpWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

private func parseHTTPDate(_ raw: Substring) -> Date? {
  let fields = raw.split(separator: " ")
  guard fields.count == 6, fields[5] == "GMT" else { return nil }

  guard fields[0].hasSuffix(","),
        httpWeekdays.contains(where: { $0 == fields[0].dropLast() })
  else { return nil }
  guard let day = Int(fields[1]), (1 ... 31).contains(day) else { return nil }
  guard let month = httpMonths.firstIndex(where: { $0 == fields[2] })
  else { return nil }
  guard let year = Int(fields[3]), fields[3].count == 4 else { return nil }

  let clock = fields[4].split(separator: ":")
  guard clock.count == 3,
        let hour = Int(clock[0]), (0 ... 23).contains(hour),
        let minute = Int(clock[1]), (0 ... 59).contains(minute),
        let second = Int(clock[2]), (0 ... 60).contains(second)
  else { return nil }

  // Days since epoch for the proleptic Gregorian calendar (Howard Hinnant's
  // civil_from_days inverse), exact for the whole HTTP-relevant range.
  let shiftedYear = month < 2 ? year - 1 : year
  let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
  let yearOfEra = shiftedYear - era * 400
  let dayOfYear = (153 * (month + (month > 1 ? -2 : 10)) + 2) / 5 + day - 1
  let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
  let days = era * 146_097 + dayOfEra - 719_468

  let seconds = TimeInterval(days * 86400 + hour * 3600 + minute * 60 + second)
  return Date(timeIntervalSince1970: seconds)
}
