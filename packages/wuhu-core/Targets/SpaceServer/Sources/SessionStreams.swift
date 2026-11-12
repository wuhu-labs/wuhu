import Fetch
import Foundation
import Logging
import Serve
import ServeSSE
import SessionDomain
import SpaceContract
import SpaceCore
import TaskLifetime

/// Runs `produce` under `scope`, sending what it sends; its end ends the stream, and a failure is logged.
func sseResponse(
  _ name: String, scope: TaskScope, clock: any Clock<Duration>,
  _ produce: @escaping @Sendable (_ send: (SSEEvent) -> Void) async throws -> Void,
) -> Response {
  let stream = AsyncStream<SSEEvent> { continuation in
    let task = try? scope.run(name) {
      do {
        try await produce { continuation.yield($0) }
      } catch is CancellationError {
      } catch {
        Logger(label: "wuhu.sse").error("event stream failed", metadata: ["stream": "\(name)", "error": "\(error)"])
      }
      continuation.finish()
    }
    if task == nil { continuation.finish() }
    continuation.onTermination = { _ in task?.cancel() }
  }
  return .sse(stream, heartbeat: .seconds(1), clock: clock)
}

func conversationStreamResponse(
  space: Space,
  scope: TaskScope,
  store: SessionStore,
  conversation: ConversationID,
  after: Int64,
  viewer: GroupID,
  reader: String? = nil,
  clock: any Clock<Duration>,
) -> Response {
  let principal = Principal(actor: reader.map { .person(persona: $0, account: AccountID(rawValue: $0)) } ?? .anonymous, group: viewer)
  return sseResponse("conversation-events", scope: scope, clock: clock) { send in
    for try await batch in store.observeConversation(conversation, after: after, as: principal) {
      for payload in try await messagePayloads(batch, sessions: store, space: space, viewer: viewer) {
        send(try .json(payload))
      }
    }
  }
}
