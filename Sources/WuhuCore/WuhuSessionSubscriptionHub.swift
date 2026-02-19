import Foundation

/// In-process pub/sub for transport-agnostic ``SessionEvent`` updates.
///
/// Used by the server to implement race-free SSE subscriptions.
actor WuhuSessionSubscriptionHub {
  private var subscribers: [String: [UUID: AsyncStream<SessionEvent>.Continuation]] = [:]

  func subscribe(sessionID: String) -> AsyncStream<SessionEvent> {
    AsyncStream(SessionEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let token = UUID()
      subscribers[sessionID, default: [:]][token] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeSubscriber(sessionID: sessionID, token: token) }
      }
    }
  }

  func publish(sessionID: String, event: SessionEvent) {
    guard let sessionSubs = subscribers[sessionID], !sessionSubs.isEmpty else { return }
    for (_, continuation) in sessionSubs {
      continuation.yield(event)
    }
  }

  private func removeSubscriber(sessionID: String, token: UUID) {
    subscribers[sessionID]?[token] = nil
    if subscribers[sessionID]?.isEmpty == true {
      subscribers[sessionID] = nil
    }
  }
}
