#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import HTTPTypes

public struct Response: Sendable {
  public var status: Status
  public var headers: Headers
  public var body: Body

  public init(
    status: Status,
    headers: Headers = Headers(),
    body: Body = .empty,
  ) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

extension Response {
  public static func json<T: Encodable>(
    _ value: T,
    status: Status = .ok,
    headers: Headers = Headers(),
    outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys],
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .secondsSince1970,
  ) throws -> Self {
    let body = try Body.json(
      value,
      outputFormatting: outputFormatting,
      dateEncodingStrategy: dateEncodingStrategy,
    )
    return Self(status: status, headers: headers.withBodyDefaults(from: body), body: body)
  }

  public static func json<T: Encodable>(
    _ value: T,
    status: Status = .ok,
    headers: Headers = Headers(),
    encoder: JSONEncoder,
  ) throws -> Self {
    let body = try Body.json(value, encoder: encoder)
    return Self(status: status, headers: headers.withBodyDefaults(from: body), body: body)
  }

  public static func text(
    _ value: String,
    status: Status = .ok,
    headers: Headers = Headers(),
    encoding: String.Encoding = .utf8,
  ) -> Self {
    let body = Body.string(value, encoding: encoding)
    return Self(status: status, headers: headers.withBodyDefaults(from: body), body: body)
  }
}

private extension Headers {
  func withBodyDefaults(from body: Body) -> Self {
    var headers = self
    if headers[.contentType] == nil, let contentType = body.contentType {
      headers[.contentType] = contentType
    }
    if let contentLength = body.contentLength {
      headers[.contentLength] = String(contentLength)
    }
    return headers
  }
}
