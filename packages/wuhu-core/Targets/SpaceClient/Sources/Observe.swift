#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import FetchSSE

public struct ObserveRequest: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case glob(String)
    case sql(String)
  }

  public var mode: Mode
  public var from: Int?
  public var throttleMs: Int?

  public init(mode: Mode, from: Int? = nil, throttleMs: Int? = nil) {
    self.mode = mode
    self.from = from
    self.throttleMs = throttleMs
  }
}

extension SpaceClient {
  public func sse(_ path: String) async throws -> AsyncThrowingStream<SSEEvent, Error> {
    let response = try await self.observeFetch(Request(url: try self.url(path)))
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    return response.sse()
  }

  public func observe(_ request: ObserveRequest) async throws -> AsyncThrowingStream<SSEEvent, Error> {
    let response = try await self.observeFetch(Request(url: try self.observeURL(request)))
    guard 200 ..< 300 ~= response.status.code else {
      throw await Self.failure(from: response)
    }
    return response.sse()
  }

  private func observeURL(_ request: ObserveRequest) throws -> URL {
    guard var components = URLComponents(url: try self.url("/v1/observe"), resolvingAgainstBaseURL: false) else {
      throw InvalidSpace(space: self.base)
    }
    var items: [URLQueryItem]
    switch request.mode {
    case let .glob(pattern):
      items = [URLQueryItem(name: "glob", value: pattern)]
      if let from = request.from {
        items.append(URLQueryItem(name: "from", value: String(from)))
      }
    case let .sql(query):
      items = [URLQueryItem(name: "sql", value: query)]
    }
    if let throttleMs = request.throttleMs {
      items.append(URLQueryItem(name: "throttleMs", value: String(throttleMs)))
    }
    components.queryItems = items
    guard let url = components.url else {
      throw InvalidSpace(space: self.base)
    }
    return url
  }
}
