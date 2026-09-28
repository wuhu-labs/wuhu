import Fetch
import Serve

public struct WebSocketUpgradeRefused: Error, Sendable {
  public let request: Request
}

public enum ServeTesting {
  public enum Upgrade: Sendable {
    case response(Response)
    case webSocket(WebSocket, serve: @Sendable () async -> Void)
  }

  public static func client(_ handler: @escaping Handler) -> FetchClient {
    FetchClient { request in try await dispatch(handler, request) }
  }

  public static func client(upgrading handler: @escaping UpgradingHandler) -> FetchClient {
    self.client { request in
      switch try await handler(request) {
      case let .response(response): return response
      case .webSocket: throw WebSocketUpgradeRefused(request: request)
      }
    }
  }

  public static func upgrade(_ handler: @escaping UpgradingHandler, _ request: Request) async throws -> Upgrade {
    do {
      switch try await handler(onTheWire(request)) {
      case let .response(response):
        return .response(response)
      case let .webSocket(session):
        let (server, client) = WebSocket.pair()
        return .webSocket(client, serve: { await session(server) })
      }
    } catch let error as ServeError {
      return .response(errorResponse(error))
    }
  }

  private static func dispatch(_ handler: @escaping Handler, _ request: Request) async throws -> Response {
    do {
      return try await handler(onTheWire(request))
    } catch let error as ServeError {
      return errorResponse(error)
    }
  }

  private static func errorResponse(_ error: ServeError) -> Response {
    let status = error.responseStatus
    return .text("\(status.code) \(status.reasonPhrase)\n", status: status)
  }

  // A real transport serializes every header onto the wire; the in-process
  // handler reads only `values`, so headers the client marked sensitive would
  // otherwise be invisible. Fold them in to match what a socket server sees.
  private static func onTheWire(_ request: Request) -> Request {
    guard !request.headers.sensitiveValues.isEmpty else { return request }
    var request = request
    for (name, value) in request.headers.sensitiveValues {
      request.headers.set(name, value)
    }
    return request
  }
}
