#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import FetchSSE
import JSONValue

public struct ObserveRequest: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case glob(String)
    case sql(String)
  }

  public var mode: Mode
  public var from: Int?
  public var throttleMs: Int?
  public var batch: Bool?
  /// SQL mode: bound parameters, and `typed` for the typed-row rendering a
  /// script's `observe` tag wants.
  public var parameters: [JSONValue]
  public var typed: Bool

  public init(mode: Mode, from: Int? = nil, throttleMs: Int? = nil, batch: Bool? = nil, parameters: [JSONValue] = [], typed: Bool = false) {
    self.mode = mode
    self.from = from
    self.throttleMs = throttleMs
    self.batch = batch
    self.parameters = parameters
    self.typed = typed
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
      if request.batch == true {
        items.append(URLQueryItem(name: "batch", value: "1"))
      }
      if let from = request.from {
        items.append(URLQueryItem(name: "from", value: String(from)))
      }
    case let .sql(query):
      items = [URLQueryItem(name: "sql", value: query)]
      if !request.parameters.isEmpty {
        items.append(URLQueryItem(name: "params", value: JSONValue.array(request.parameters).jsonString()))
      }
      if request.typed {
        items.append(URLQueryItem(name: "typed", value: "1"))
      }
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
