import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import WebPush

struct WebPushMessage: Hashable, Sendable {
  var endpoint: String
  var p256dh: String
  var auth: String
  var vapidKeyID: String
  var destination: URL
  /// The notification's group (the conversation's, or the session's).
  var group: String
  var title: String
  var body: String
  var tag: String
  var topic: String
  var timestamp: Date
}

struct WebPushTransportError: Error, Sendable {
  var status: Int?
  var retryAfter: String?
  var underlying: String
}

struct WebPushClient: Sendable {
  var send: @Sendable (WebPushMessage) async throws -> Void

  static func live(manager: WebPushManager, logger: Logger) -> WebPushClient {
    WebPushClient { message in
      do {
        guard message.vapidKeyID == manager.nextVAPIDKeyID.description,
              let endpoint = URL(string: message.endpoint)
        else {
          throw WebPushTransportError(status: 410, retryAfter: nil, underlying: "obsolete subscription")
        }
        let subscriber = try Subscriber(
          endpoint: endpoint,
          userAgentKeyMaterial: UserAgentKeyMaterial(
            publicKey: message.p256dh,
            authenticationSecret: message.auth,
          ),
          vapidKeyID: manager.nextVAPIDKeyID,
        )
        let notification = PushMessage.Notification(
          destination: message.destination,
          title: message.title,
          body: message.body,
          timestamp: message.timestamp,
          data: WebPushNavigation(destination: message.destination.absoluteString, group: message.group),
          options: PushMessage.NotificationOptions(tag: message.tag),
        )
        try await manager.send(
          notification: notification,
          to: subscriber,
          encodableDeduplicationTopic: message.topic,
          expiration: .hours(24),
          urgency: .normal,
          logger: logger,
        )
      } catch let error as WebPushTransportError {
        throw error
      } catch let error as PushServiceError {
        throw await WebPushTransportError(error)
      } catch {
        throw WebPushTransportError(status: nil, retryAfter: nil, underlying: String(describing: error))
      }
    }
  }
}

extension WebPushTransportError {
  init(_ error: PushServiceError) async {
    let body = (try? await error.response.body.collect(upTo: 1024)).map(String.init(buffer:)) ?? ""
    self.init(
      status: Int(error.response.status.code),
      retryAfter: error.response.headers.first(name: "retry-after"),
      underlying: body.isEmpty ? String(describing: error) : "\(error.response.status) \(body)",
    )
  }
}

private struct WebPushNavigation: Codable, Hashable, Sendable {
  var destination: String
  var group: String
}
