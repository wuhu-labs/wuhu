#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import HTTPTypes

public struct Request: Sendable {
  public var url: URL
  public var method: Method
  public var headers: RequestHeaders
  public var body: Body?

  public init(
    url: URL,
    method: Method = .get,
    headers: RequestHeaders = RequestHeaders(),
    body: Body? = nil,
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }

  public init(
    url: URL,
    method: Method = .get,
    headers: Headers,
    body: Body? = nil,
  ) {
    self.init(
      url: url,
      method: method,
      headers: RequestHeaders(headers),
      body: body,
    )
  }
}

extension Request {
  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .secondsSince1970,
  ) async throws -> T {
    try await (self.body ?? .empty).json(
      type,
      upTo: limit,
      dateDecodingStrategy: dateDecodingStrategy,
    )
  }

  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    decoder: JSONDecoder,
  ) async throws -> T {
    try await (self.body ?? .empty).json(type, upTo: limit, decoder: decoder)
  }
}

extension Request {
  public var isReplayable: Bool {
    self.body?.isReplayable ?? true
  }

  public func replay() -> Self? {
    if let body = self.body {
      guard let replayedBody = body.replay() else {
        return nil
      }

      return Self(
        url: self.url,
        method: self.method,
        headers: self.headers,
        body: replayedBody,
      )
    } else {
      return self
    }
  }
}
