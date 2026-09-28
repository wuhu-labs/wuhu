#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

public typealias Handler = @Sendable (Request) async throws -> Response

public struct ServeOptions: Sendable {
  public var scheme: String
  public var defaultHost: String
  public var maximumHeadBytes: Int
  public var maximumHeaderLineBytes: Int
  public var maximumHeaderCount: Int
  public var maximumBodyBytes: Int
  public var maximumWebSocketFrameBytes: Int
  public var requestBodyHighWatermarkBytes: Int
  public var requestBodyLowWatermarkBytes: Int
  public var keepAliveIdleTimeout: Duration?
  // A read-gap (inactivity) timeout, not a total request deadline. Two slowloris
  // shapes survive it as accepted gaps, both requiring a whole-request deadline
  // to close (future work): a body dribbled one byte per interval stays open up
  // to the body cap; and, on a reused keep-alive connection, a next-request
  // header dribbled one byte per interval never completes a head — the timers
  // only reap a fully silent client, and the pre-decode head-byte cap
  // (HTTPHeadLimitHandler) is armed for the first request on a connection.
  public var requestReadInactivityTimeout: Duration?

  public init(
    scheme: String = "http",
    defaultHost: String = "localhost",
    maximumHeadBytes: Int = 16 * 1024,
    maximumHeaderLineBytes: Int = 8 * 1024,
    maximumHeaderCount: Int = 100,
    maximumBodyBytes: Int = 8 * 1024 * 1024,
    maximumWebSocketFrameBytes: Int = 1 << 20,
    requestBodyHighWatermarkBytes: Int = 512 * 1024,
    requestBodyLowWatermarkBytes: Int = 128 * 1024,
    keepAliveIdleTimeout: Duration? = .seconds(75),
    requestReadInactivityTimeout: Duration? = .seconds(60),
  ) {
    self.scheme = scheme
    self.defaultHost = defaultHost
    self.maximumHeadBytes = maximumHeadBytes
    self.maximumHeaderLineBytes = maximumHeaderLineBytes
    self.maximumHeaderCount = maximumHeaderCount
    self.maximumBodyBytes = maximumBodyBytes
    self.maximumWebSocketFrameBytes = maximumWebSocketFrameBytes
    self.requestBodyHighWatermarkBytes = requestBodyHighWatermarkBytes
    self.requestBodyLowWatermarkBytes = requestBodyLowWatermarkBytes
    self.keepAliveIdleTimeout = keepAliveIdleTimeout
    self.requestReadInactivityTimeout = requestReadInactivityTimeout
  }
}

public enum ServeError: Error, Equatable, Sendable {
  case conflictingBodyHeaders
  case duplicateHeader(String)
  case headerLineTooLarge(limit: Int)
  case headersTooLarge(limit: Int)
  case invalidChunkSize
  case invalidChunkTerminator
  case invalidContentLength
  case invalidHeaderLine
  case invalidRequestLine
  case invalidRequestTarget(String)
  case invalidURL(String)
  case missingHostHeader
  case requestBodyTooLarge(limit: Int)
  case tooManyHeaders(limit: Int)
  case unexpectedRequestBody
  case unsupportedHTTPVersion(String)
  case unsupportedTransferEncoding(String)
  case unexpectedEndOfStream
  case webSocketClosed
}

public enum Serve {}

extension Request {
  public func discardBody() async throws {
    try await self.body?.discard()
  }

  public func requireNoBody() throws {
    guard self.body == nil else {
      throw ServeError.unexpectedRequestBody
    }
  }
}

extension ServeError {
  public var responseStatus: Status {
    switch self {
    case .headerLineTooLarge, .headersTooLarge, .tooManyHeaders:
      return .requestHeaderFieldsTooLarge
    case .requestBodyTooLarge:
      return .contentTooLarge
    case let .unsupportedHTTPVersion(version):
      return Status(code: 505, reasonPhrase: "Unsupported HTTP Version (\(version))")
    default:
      return .badRequest
    }
  }
}

extension Serve {
  public static func requestURL(
    target: String,
    method: Fetch.Method,
    host: String,
    options: ServeOptions,
  ) throws -> URL {
    guard !target.isEmpty, !target.contains("#" as Character) else {
      throw ServeError.invalidRequestTarget(target)
    }

    if target.hasPrefix("http://") || target.hasPrefix("https://") {
      guard let url = URL(string: target), url.host != nil else {
        throw ServeError.invalidURL(target)
      }
      return url
    }

    guard target.hasPrefix("/") else {
      throw ServeError.invalidRequestTarget(target)
    }

    if method == .connect {
      throw ServeError.invalidRequestTarget(target)
    }

    let urlString = "\(options.scheme)://\(host)\(target)"
    guard let url = URL(string: urlString) else {
      throw ServeError.invalidURL(urlString)
    }
    return url
  }

  public static func responseAllowsBody(_ status: Status) -> Bool {
    !(100 ..< 200).contains(status.code) && status.code != 204 && status.code != 304
  }

  public static func firstHeaderValue(named rawName: String, in headers: Headers) -> String? {
    for field in headers where field.name.rawName.lowercased() == rawName.lowercased() {
      return field.value
    }
    return nil
  }
}
