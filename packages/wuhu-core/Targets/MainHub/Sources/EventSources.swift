import Dependencies
import Fetch
import FetchSSE
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import SpaceCore

/// Where a stream subscription's events come from. Every connection carries a
/// fresh OIDC token naming the subscriber, for the stream's origin, and goes
/// out on a transport that follows no redirect, so the token reaches that
/// origin alone.
public struct EventSources: Sendable {
  let token: @Sendable (SubscriptionOwner, _ audience: URL) async throws -> String
  let fetch: FetchClient

  public init(token: @escaping @Sendable (SubscriptionOwner, _ audience: URL) async throws -> String, fetch: FetchClient) {
    self.token = token
    self.fetch = fetch
  }

  static let unavailable = EventSources(token: { _, _ in throw StreamFailure.refused("this server dials no event streams") }, fetch: FetchClient { _ in
    throw FetchError.unimplemented
  })

  /// The events `url` sends `owner`, after `lastEventID` (empty: none). A
  /// status the stream may get past by waiting throws
  /// ``StreamFailure/unavailable(retryAfter:)``; any other answer but an event
  /// stream, ``StreamFailure/refused(_:)``.
  func open(_ url: URL, as owner: SubscriptionOwner, after lastEventID: String) async throws -> SSEEvents {
    guard let audience = fetchOrigin(url).flatMap(URL.init(string:)) else {
      throw StreamFailure.refused("\(url) is not an http(s) URL with a plain host")
    }
    var request = Request(url: url)
    request.headers.set(.accept, "text/event-stream")
    let resumed = lastEventID.isEmpty ? nil : lastEventID
    request.headers.set("Last-Event-ID", resumed)
    request.headers.setSensitive(.authorization, "Bearer " + (try await token(owner, audience)))
    let response = try await fetch(request)
    switch response.status.code {
    case 200 where response.body.contentType?.lowercased().hasPrefix("text/event-stream") == true:
      return response.sseEvents(after: resumed)
    case 200:
      throw StreamFailure.refused("\(url) answered \(response.body.contentType ?? "no content type"), not text/event-stream")
    case 408, 429, 500 ... 599:
      throw StreamFailure.unavailable(retryAfter: response.headers[.retryAfter].flatMap(waitFor))
    default:
      throw StreamFailure.refused("\(url) answered HTTP \(response.status.code)")
    }
  }
}

/// A `Retry-After` value, in seconds or as an HTTP date.
private func waitFor(_ retryAfter: String) -> Duration? {
  @Dependency(\.date.now) var now
  if let seconds = Int(retryAfter) { return .seconds(max(seconds, 0)) }
  guard let date = try? Date.HTTPFormatStyle().parse(retryAfter) else { return nil }
  return .seconds(max(date.timeIntervalSince(now), 0))
}

enum StreamFailure: Error {
  case refused(String)
  case unavailable(retryAfter: Duration?)
}
