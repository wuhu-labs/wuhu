#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies

extension Response {
  @discardableResult
  public func validateStatus() throws -> Self {
    try self.validateStatus(200 ..< 300)
  }

  @discardableResult
  public func validateStatus(_ range: Range<Int>) throws -> Self {
    guard range.contains(self.status.code) else {
      throw FetchError.unexpectedStatus(self.status)
    }
    return self
  }

  public func bytes(upTo limit: Int? = nil) async throws -> Bytes {
    try await self.body.bytes(upTo: limit)
  }

  public func data(upTo limit: Int? = nil) async throws -> Data {
    try await self.body.data(upTo: limit)
  }

  public func text(
    upTo limit: Int? = nil,
    encoding: String.Encoding = .utf8,
  ) async throws -> String {
    try await self.body.text(upTo: limit, encoding: encoding)
  }

  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .secondsSince1970,
  ) async throws -> T {
    try await self.body.json(type, upTo: limit, dateDecodingStrategy: dateDecodingStrategy)
  }

  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    decoder: JSONDecoder,
  ) async throws -> T {
    try await self.body.json(type, upTo: limit, decoder: decoder)
  }

  /// The wait `Retry-After` asks for, in delta seconds or as an HTTP date measured from `\.date.now`; never negative. Before
  /// macOS and iOS 26, which first parse HTTP dates, a date is unreadable.
  public var retryAfter: Duration? {
    guard let value = self.headers[.retryAfter] else { return nil }
    if let seconds = Int(value) { return .seconds(max(seconds, 0)) }
    guard #available(macOS 26, iOS 26, *), let date = try? Date.HTTPFormatStyle().parse(value) else { return nil }
    @Dependency(\.date.now) var now
    return .seconds(max(date.timeIntervalSince(now), 0))
  }
}
