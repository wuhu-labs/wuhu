#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import Serve

public typealias RouteHandler = @Sendable (_ request: Request, _ parameters: RouteParameters) async throws -> Response
public typealias WebSocketRouteHandler = @Sendable (_ request: Request, _ parameters: RouteParameters) async throws -> UpgradeResult
public typealias Middleware = @Sendable (_ next: @escaping Handler) -> Handler

public struct RouteParameters: Sendable, Equatable {
  private let storage: [String: String]

  public init(_ storage: [String: String] = [:]) {
    self.storage = storage
  }

  public var isEmpty: Bool {
    self.storage.isEmpty
  }

  public subscript(_ name: String) -> String? {
    self.storage[name].map(percentDecoded)
  }

  public var values: [String: String] {
    self.storage.mapValues(percentDecoded)
  }

  public var rawValues: [String: String] {
    self.storage
  }
}

func percentDecoded(_ raw: String) -> String {
  percentDecodedString(raw) ?? raw
}

func percentDecodedString(_ raw: some StringProtocol) -> String? {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(raw.utf8.count)
  var iterator = raw.utf8.makeIterator()
  while let byte = iterator.next() {
    guard byte == UInt8(ascii: "%") else {
      bytes.append(byte)
      continue
    }
    guard let high = iterator.next().flatMap(asciiHexNibble),
          let low = iterator.next().flatMap(asciiHexNibble)
    else { return nil }
    bytes.append(high << 4 | low)
  }
  return String(validating: bytes, as: UTF8.self)
}

private func asciiHexNibble(_ byte: UInt8) -> UInt8? {
  switch byte {
  case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
  case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
  case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
  default: nil
  }
}

public struct Router: Sendable {
  private var routes: [Route] = []
  private var webSocketRoutes: [WebSocketRoute] = []
  private var middlewares: [Middleware] = []

  public init() {}

  public mutating func on(
    _ method: Fetch.Method,
    _ path: String,
    use handler: @escaping RouteHandler,
  ) {
    self.routes.append(
      Route(
        method: method,
        path: PathPattern(path),
        handler: handler,
      ),
    )
  }

  public mutating func get(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.get, path, use: handler)
  }

  public mutating func post(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.post, path, use: handler)
  }

  public mutating func put(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.put, path, use: handler)
  }

  public mutating func patch(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.patch, path, use: handler)
  }

  public mutating func delete(_ path: String, use handler: @escaping RouteHandler) {
    self.on(Fetch.Method.delete, path, use: handler)
  }

  public mutating func webSocket(_ path: String, use handler: @escaping WebSocketRouteHandler) {
    self.webSocketRoutes.append(WebSocketRoute(path: PathPattern(path), handler: handler))
  }

  public mutating func mount(_ prefix: String, _ router: Router) {
    let prefixPattern = PathPattern(prefix)
    self.routes.append(
      contentsOf: router.routes.map { route in
        Route(
          method: route.method,
          path: route.path.prefixed(by: prefixPattern),
          handler: applyingMiddlewares(router.middlewares, to: route.handler),
        )
      },
    )
    self.webSocketRoutes.append(
      contentsOf: router.webSocketRoutes.map { route in
        WebSocketRoute(path: route.path.prefixed(by: prefixPattern), handler: route.handler)
      },
    )
  }

  public mutating func use(_ middleware: @escaping Middleware) {
    self.middlewares.append(middleware)
  }

  public var handler: Handler {
    precondition(self.webSocketRoutes.isEmpty, "Routers with webSocket routes must be served through upgradingHandler")
    let dispatch = self.dispatchHandler
    return applyMiddlewares(self.middlewares, to: dispatch)
  }

  public var upgradingHandler: UpgradingHandler {
    let routes = self.routes
    let webSocketRoutes = self.webSocketRoutes
    let httpHandler = applyMiddlewares(self.middlewares, to: self.dispatchHandler)
    return { request in
      guard let rawPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
        preconditionFailure("URLComponents cannot parse a URL that URL already represents: \(request.url)")
      }
      let pathSegments = PathPattern.segments(for: rawPath)
      // The most specific matching pattern wins, by the same rule as HTTP
      // dispatch, so a catch-all registered first never shadows a specific
      // route.
      var match: (route: WebSocketRoute, parameters: RouteParameters)?
      for route in webSocketRoutes {
        guard let parameters = route.path.match(pathSegments) else { continue }
        if let current = match, !route.path.isMoreSpecific(than: current.route.path) { continue }
        match = (route, parameters)
      }
      guard let (route, parameters) = match else {
        return .response(try await httpHandler(request))
      }
      // Plain routes may share a webSocket route's path (an HTTP GET status
      // next to the upgrade endpoint): a non-upgrade request goes to HTTP
      // dispatch whenever a plain route claims the path and method, and only
      // an unclaimed one falls back to 426.
      guard Serve.isWebSocketUpgradeRequest(request) else {
        let claimed = routes.contains { $0.method == request.method && $0.path.match(pathSegments) != nil }
        if claimed {
          return .response(try await httpHandler(request))
        }
        var headers = Headers()
        headers[.upgrade] = "websocket"
        return .response(plainTextResponse(status: .upgradeRequired, headers: headers))
      }
      return try await route.handler(request, parameters)
    }
  }

  private var dispatchHandler: Handler {
    let routes = self.routes
    return { request in
      guard let rawPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
        preconditionFailure("URLComponents cannot parse a URL that URL already represents: \(request.url)")
      }
      let pathSegments = PathPattern.segments(for: rawPath)

      // Darwin's URL layer normalizes a malformed `%`, so this only rejects on the
      // WHATWG parser (Linux), where `percentEncodedPath` can carry an un-decodable
      // segment that must not reach a handler raw.
      guard pathSegments.allSatisfy({ percentDecodedString($0) != nil }) else {
        return plainTextResponse(status: .badRequest)
      }

      var pathMatches: [(route: Route, parameters: RouteParameters)] = []
      var bestMethodMatch: (route: Route, parameters: RouteParameters)?

      for route in routes {
        guard let parameters = route.path.match(pathSegments) else { continue }
        pathMatches.append((route, parameters))

        guard route.method == request.method else { continue }

        if let current = bestMethodMatch {
          if route.path.isMoreSpecific(than: current.route.path) {
            bestMethodMatch = (route, parameters)
          }
        } else {
          bestMethodMatch = (route, parameters)
        }
      }

      if let bestMethodMatch {
        return try await bestMethodMatch.route.handler(request, bestMethodMatch.parameters)
      }

      if !pathMatches.isEmpty {
        var headers = Headers()
        let allow = pathMatches
          .map(\.route.method.rawValue)
          .sorted()
          .joined(separator: ", ")
        headers[.allow] = allow
        return plainTextResponse(status: .methodNotAllowed, headers: headers)
      }

      return plainTextResponse(status: .notFound)
    }
  }
}

public func applyMiddlewares(
  _ middlewares: [Middleware],
  to handler: @escaping Handler,
) -> Handler {
  middlewares.reversed().reduce(handler) { next, middleware in
    middleware(next)
  }
}

private struct Route: Sendable {
  let method: Fetch.Method
  let path: PathPattern
  let handler: RouteHandler
}

private struct WebSocketRoute: Sendable {
  let path: PathPattern
  let handler: WebSocketRouteHandler
}

private func applyingMiddlewares(
  _ middlewares: [Middleware],
  to handler: @escaping RouteHandler,
) -> RouteHandler {
  guard !middlewares.isEmpty else { return handler }

  return { request, parameters in
    let endpoint: Handler = { request in
      try await handler(request, parameters)
    }
    return try await applyMiddlewares(middlewares, to: endpoint)(request)
  }
}

private struct PathPattern: Sendable, Equatable {
  let segments: [Segment]

  init(_ rawPath: String) {
    precondition(rawPath.hasPrefix("/"), "Route paths must start with '/'")
    self.segments = Self.segments(for: rawPath).map(Segment.init)

    for segment in self.segments {
      if case let .parameter(name) = segment {
        precondition(!name.isEmpty, "Route parameter names must not be empty")
      }
    }
  }

  init(segments: [Segment]) {
    self.segments = segments
  }

  func prefixed(by prefix: PathPattern) -> Self {
    Self(segments: prefix.segments + self.segments)
  }

  func match(_ pathSegments: [String]) -> RouteParameters? {
    var parameters: [String: String] = [:]
    var pathIndex = pathSegments.startIndex

    for segment in self.segments {
      switch segment {
      case .catchAll:
        return RouteParameters(parameters)

      case let .literal(literal):
        guard pathIndex < pathSegments.endIndex,
              literal == percentDecoded(pathSegments[pathIndex]) else { return nil }
        pathIndex = pathSegments.index(after: pathIndex)

      case let .parameter(name):
        guard pathIndex < pathSegments.endIndex else { return nil }
        parameters[name] = pathSegments[pathIndex]
        pathIndex = pathSegments.index(after: pathIndex)
      }
    }

    guard pathIndex == pathSegments.endIndex else { return nil }
    return RouteParameters(parameters)
  }

  func isMoreSpecific(than other: PathPattern) -> Bool {
    if self.literalCount != other.literalCount {
      return self.literalCount > other.literalCount
    }
    return self.segments.count > other.segments.count
  }

  var literalCount: Int {
    self.segments.reduce(into: 0) { count, segment in
      if case .literal = segment {
        count += 1
      }
    }
  }

  static func segments(for rawPath: String) -> [String] {
    rawPath
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
  }

  enum Segment: Sendable, Equatable {
    case literal(String)
    case parameter(String)
    case catchAll

    init(_ rawValue: String) {
      if rawValue == "*" {
        self = .catchAll
      } else if rawValue.hasPrefix(":") {
        self = .parameter(String(rawValue.dropFirst()))
      } else {
        self = .literal(rawValue)
      }
    }
  }
}

private func plainTextResponse(
  status: Status,
  headers: Headers = Headers(),
) -> Response {
  var responseHeaders = headers
  responseHeaders[.contentType] = "text/plain; charset=utf-8"
  let bodyText = "\(status.code) \(status.reasonPhrase)\n"
  let body = Body.string(bodyText)
  responseHeaders[.contentLength] = String(bodyText.utf8.count)
  return Response(status: status, headers: responseHeaders, body: body)
}
