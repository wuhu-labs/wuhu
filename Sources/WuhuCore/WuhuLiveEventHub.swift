import Foundation

actor WuhuLiveEventHub {
  private var subscribers: [String: [UUID: AsyncStream<WuhuSessionStreamEvent>.Continuation]] = [:]

  func subscribe(sessionID: String) -> AsyncStream<WuhuSessionStreamEvent> {
    AsyncStream(WuhuSessionStreamEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let token = UUID()
      subscribers[sessionID, default: [:]][token] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeSubscriber(sessionID: sessionID, token: token) }
      }
    }
  }

  func publish(sessionID: String, event: WuhuSessionStreamEvent) {
    guard var sessionSubs = subscribers[sessionID], !sessionSubs.isEmpty else { return }
    for (token, continuation) in sessionSubs {
      continuation.yield(event)
      sessionSubs[token] = continuation
    }
    subscribers[sessionID] = sessionSubs
  }

  private func removeSubscriber(sessionID: String, token: UUID) {
    subscribers[sessionID]?[token] = nil
    if subscribers[sessionID]?.isEmpty == true {
      subscribers[sessionID] = nil
    }
  }
}
