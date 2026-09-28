import Dependencies
import Fetch
import Foundation

struct PushRelayMessage: Hashable, Sendable {
  var endpoint: String
  var token: String
  var idempotencyKey: String
  var title: String
  var subtitle: String?
  var body: String
  var threadID: String
  var collapseKey: String
  var badge: Int
  var data: [String: String]
}

struct PushRelayTransportError: Error, Sendable {
  var status: Int?
  var retryAfter: String?
  var underlying: String
}

struct PushRelayClient: Sendable {
  var send: @Sendable (PushRelayMessage) async throws -> Void

  static func live(fetch: FetchClient) -> PushRelayClient {
    PushRelayClient { message in
      guard let url = URL(string: message.endpoint) else {
        throw PushRelayTransportError(status: 410, retryAfter: nil, underlying: "unusable endpoint")
      }
      let response: Response
      do {
        var request = Request(url: url, method: .post)
        request.headers.setSensitive(.authorization, "Bearer " + message.token)
        request.body = try .json(PushRelayEnvelope(message))
        response = try await fetch(request)
      } catch {
        throw PushRelayTransportError(status: nil, retryAfter: nil, underlying: String(describing: error))
      }
      guard 200 ..< 300 ~= response.status.code else {
        // The gateway's body may name the refusal; it never carries the device
        // token, so logging it is safe.
        let body = (try? await response.text()) ?? ""
        throw PushRelayTransportError(
          status: response.status.code,
          retryAfter: response.headers[.retryAfter],
          underlying: body.isEmpty ? "HTTP \(response.status.code)" : body,
        )
      }
    }
  }
}

private struct PushRelayEnvelope: Encodable {
  var idempotencyKey: String
  var priority: String
  var collapseKey: String
  var notification: Notification

  init(_ message: PushRelayMessage) {
    self.idempotencyKey = message.idempotencyKey
    self.priority = "normal"
    self.collapseKey = message.collapseKey
    self.notification = Notification(
      title: message.title,
      subtitle: message.subtitle,
      body: message.body,
      threadID: message.threadID,
      badge: message.badge,
      sound: "default",
      data: message.data,
    )
  }

  enum CodingKeys: String, CodingKey {
    case idempotencyKey = "idempotency_key"
    case priority
    case collapseKey = "collapse_key"
    case notification
  }

  struct Notification: Encodable {
    var title: String
    var subtitle: String?
    var body: String
    var threadID: String
    var badge: Int
    var sound: String
    var data: [String: String]

    enum CodingKeys: String, CodingKey {
      case title
      case subtitle
      case body
      case threadID = "thread_id"
      case badge
      case sound
      case data
    }
  }
}
