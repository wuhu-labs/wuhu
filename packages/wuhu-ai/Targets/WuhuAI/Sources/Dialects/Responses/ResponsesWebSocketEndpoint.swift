import Clocks
import Dependencies
import Fetch
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections

public struct ResponsesWebSocketObserver: Sendable {
  public var request: @Sendable (Int, RequestHeaders, JSONValue) async -> Void
  public var received: @Sendable (Int, WebSocketMessage) async -> Void
  public var event: @Sendable (Int, JSONValue) async -> Void

  public init(
    request: @escaping @Sendable (Int, RequestHeaders, JSONValue) async -> Void = { _, _, _ in },
    received: @escaping @Sendable (Int, WebSocketMessage) async -> Void = { _, _ in },
    event: @escaping @Sendable (Int, JSONValue) async -> Void = { _, _ in },
  ) {
    self.request = request
    self.event = event
    self.received = received
  }
}

extension ResponsesEndpoint {
  public func withWebSocket(
    session: ResponsesWebSocketSession,
    attemptID: String,
    observer: ResponsesWebSocketObserver = .init(),
    receiveQuota: @escaping @Sendable (JSONValue) async -> Void = { _ in },
  ) -> some ModelEndpoint {
    ResponsesWebSocketEndpoint(endpoint: self, session: session, attemptID: attemptID, observer: observer, receiveQuota: receiveQuota)
  }
}

private struct ResponsesWebSocketEndpoint<Base: ResponsesEndpoint>: ModelEndpoint {
  let endpoint: Base
  let session: ResponsesWebSocketSession
  let attemptID: String
  let observer: ResponsesWebSocketObserver
  let receiveQuota: @Sendable (JSONValue) async -> Void
  var providerID: String { endpoint.providerID }
  var model: String { endpoint.model }

  func runInference(context: Context, options: RequestOptions, mediaResolver: (any MediaResolver)?) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    @Dependency(WebSocketConnector.self) var connector
    @Dependency(\.continuousClock) var clock
    let capturedClock = AnyClock(clock)
    let dialer = connector
    let receiveHeaders: @Sendable ([String: String]) async -> Void = (endpoint as? any ResponsesHeaderReceiving)?.receiveResponseHeaders ?? { @Sendable _ in }
    let build: @Sendable (Context) async throws -> ResponsesSocketRequest = { context in
      let built = try await buildResponsesRequest(
        model: endpoint.model, baseURL: endpoint.baseURL,
        context: normalizedRequestContext(context, targetProviderID: endpoint.providerID),
        options: options, isCodex: endpoint.isCodex, mediaResolver: mediaResolver,
      )
      var body = built.body
      endpoint.modifyBody(&body, options: options)
      body.removeValue(forKey: "stream")
      body.removeValue(forKey: "background")
      body.removeValue(forKey: "previous_response_id")
      body["type"] = .string("response.create")
      var headers = RequestHeaders(values: built.headers)
      endpoint.modifyHeaders(&headers, options: options)
      if endpoint.isCodex { headers.set("OpenAI-Beta", "responses_websockets=2026-02-06") }
      var components = URLComponents(url: built.url, resolvingAgainstBaseURL: false)
      switch components?.scheme {
      case "https": components?.scheme = "wss"
      case "http": components?.scheme = "ws"
      case "ws", "wss": break
      default: throw WebSocketError.invalidURL(built.url.absoluteString)
      }
      guard let url = components?.url else { throw WebSocketError.invalidURL(built.url.absoluteString) }
      let size = 16 << 20
      return ResponsesSocketRequest(
        handshake: WebSocketRequest(url: url, headers: headers, limits: .init(frameBytes: size, messageBytes: size, bufferedReceiveBytes: size, outboundMessageBytes: size)),
        body: body,
      )
    }
    return AsyncStream { continuation in
      let task = Task {
        do {
          let terminal = try await session.infer(
            attemptID: attemptID, context: context, build: build, connector: dialer,
            providerID: providerID, model: model, observer: observer, receiveHeaders: receiveHeaders, receiveQuota: receiveQuota,
            idleTimeout: options.idleTimeout, clock: capturedClock,
            yield: { continuation.yield(.success($0)) },
          )
          continuation.yield(.success(terminal))
        } catch is CancellationError {
        } catch {
          continuation.yield(.failure(responsesWebSocketError(error)))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

struct ResponsesSocketRequest: Sendable {
  var handshake: WebSocketRequest
  var body: OrderedDictionary<String, JSONValue>
}
