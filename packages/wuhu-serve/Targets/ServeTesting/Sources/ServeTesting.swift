import Fetch
import FetchTunnel
import Serve

public enum ServeTesting {
  public enum Upgrade: Sendable {
    case response(Response)
    case webSocket(WebSocket, serve: @Sendable () async -> Void)
  }

  public static func client(_ handler: @escaping Handler) -> FetchClient {
    .inProcess(handler)
  }

  public static func client(upgrading handler: @escaping UpgradingHandler) -> FetchClient {
    .inProcess(handler)
  }

  public static func upgrade(_ handler: @escaping UpgradingHandler, _ request: Request) async throws -> Upgrade {
    do {
      switch try await handler(onTheWire(request)) {
      case let .response(response):
        return .response(response)
      case .boundedWebSocket:
        throw TunnelError.unsupportedTransport
      case let .webSocket(session):
        let (server, client) = WebSocket.pair()
        return .webSocket(client, serve: { await session(server) })
      }
    } catch let error as ServeError {
      return .response(errorResponse(error))
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
