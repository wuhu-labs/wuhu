import Fetch

/// A fetch client over a handler called as a function: what a client in the
/// same process as the server uses in place of a socket. An upgrade is
/// refused, a `ServeError` answers as the status response a socket server
/// would send, and headers the client marked sensitive are folded in as a
/// wire transport would serialize them.
public struct WebSocketUpgradeRefused: Error, Sendable {
  public let request: Request
}

extension FetchClient {
  public static func inProcess(_ handler: @escaping UpgradingHandler) -> FetchClient {
    FetchClient { request in
      do {
        switch try await handler(onTheWire(request)) {
        case let .response(response): return response
        case .webSocket, .boundedWebSocket: throw WebSocketUpgradeRefused(request: request)
        }
      } catch let error as ServeError {
        return errorResponse(error)
      }
    }
  }

  public static func inProcess(_ handler: @escaping Handler) -> FetchClient {
    FetchClient { request in
      do {
        return try await handler(onTheWire(request))
      } catch let error as ServeError {
        return errorResponse(error)
      }
    }
  }
}

func errorResponse(_ error: ServeError) -> Response {
  let status = error.responseStatus
  return .text("\(status.code) \(status.reasonPhrase)\n", status: status)
}

// A real transport serializes every header onto the wire; the in-process
// handler reads only `values`, so headers the client marked sensitive would
// otherwise be invisible. Fold them in to match what a socket server sees.
func onTheWire(_ request: Request) -> Request {
  guard !request.headers.sensitiveValues.isEmpty else { return request }
  var request = request
  for (name, value) in request.headers.sensitiveValues {
    request.headers.set(name, value)
  }
  return request
}
