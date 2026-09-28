#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import OpenAPIRuntime

/// An `OpenAPIRuntime.ClientTransport` backed by wuhu-fetch's ``FetchClient``.
///
/// This is the client half of the OpenAPI boundary: generated `Client` code
/// speaks `HTTPRequest`/`HTTPResponse` + `HTTPBody`, and this transport bridges
/// those to a `FetchClient` closure — the same seam that already drives both
/// real remote HTTP (`.urlSession`/`.asyncHTTPClient`) and the in-process
/// embedded router (`WuhuService.inProcessFetch`). So a generated client runs
/// unchanged against a remote server, an embedded server, or a stub.
///
/// Bodies are streamed, not buffered: `HTTPBody` chunks map straight to a
/// streaming ``Body``, and the response body is handed back as a live
/// `HTTPBody`. That is what lets `text/event-stream` (SSE) responses work —
/// keep the body lazy and feed it to the runtime's SSE decoders.
public struct FetchTransport: ClientTransport {
  private let client: FetchClient

  /// - Parameter client: the wuhu-fetch client to send through. Inject
  ///   `.urlSession(...)` / `.asyncHTTPClient(...)` for network calls, the
  ///   in-process fetch for an embedded server, or a closure stub in tests.
  public init(client: FetchClient) {
    self.client = client
  }

  public func send(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID _: String,
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var fetchRequest = Request(
      url: Self.resolve(path: request.path, against: baseURL),
      method: request.method,
      headers: request.headerFields,
    )
    fetchRequest.body = body.map(Self.body(from:))

    let response = try await self.client.fetch(fetchRequest)

    let httpResponse = HTTPResponse(status: response.status, headerFields: response.headers)
    let responseBody = HTTPBody(
      response.body.asyncBytes().map { ArraySlice($0) },
      length: Self.length(of: response.body.contentLength),
      iterationBehavior: .single,
    )
    return (httpResponse, responseBody)
  }

  /// Resolve the OpenAPI request path (`/v1/...?query`, absolute from the
  /// server root because the document's server is `/`) against the injected
  /// base URL, preserving its scheme/host/port.
  private static func resolve(path: String?, against baseURL: URL) -> URL {
    guard let path, !path.isEmpty else { return baseURL }
    return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
  }

  /// Wrap a runtime `HTTPBody` as a streaming wuhu ``Body``, carrying the known
  /// length through so the transport can set `content-length`.
  private static func body(from httpBody: HTTPBody) -> Body {
    Body.stream(
      length: Self.length(of: httpBody),
      contentType: nil,
      httpBody.map { Data($0) },
    )
  }

  private static func length(of httpBody: HTTPBody) -> Int64? {
    switch httpBody.length {
    case let .known(value): value
    case .unknown: nil
    }
  }

  private static func length(of contentLength: Int64?) -> HTTPBody.Length {
    contentLength.map { .known($0) } ?? .unknown
  }
}
