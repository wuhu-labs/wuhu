import Fetch
import Foundation
import InferenceKit
import JSONValue
import Serve
import ServeSSE
import SessionDomain
import SpaceContract
import SpaceCore
import Synchronization
import struct WuhuAI.AssistantMessage

func conversationStreamResponse(
  space: Space,
  store: SessionStore,
  conversation: ConversationID,
  after: Int64,
  viewer: GroupID,
  clock: any Clock<Duration>,
) -> Response {
  let events = AsyncStream<SSEEvent> { continuation in
    let task = Task {
      do {
        for try await batch in store.observeConversation(conversation, after: after) {
          for payload in try await messagePayloads(batch, sessions: store, space: space, viewer: viewer) {
            continuation.yield(try .json(payload))
          }
        }
      } catch {}
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
  return .sse(events, heartbeat: .seconds(1), clock: clock)
}

func directStreamResponse(runtime: SessionRuntime, session: SessionID, cursor: TranscriptCursor?, bounded: Bool = false, historyEpoch: String? = nil) -> Response {
  let store = runtime.store
  let hub = runtime.attempts
  let events = AsyncStream<SSEEvent> { continuation in
    let task = Task {
      let tracker = AttemptTracker()
      await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          // Subscribe before the in-flight snapshot so no event can fall in
          // between; the tracker dedupes a started seen on both paths.
          let live = hub.events(session: session)
          for (attemptID, message) in hub.inFlight(session: session).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard tracker.start(attemptID) else { continue }
            yieldEvent(continuation, .started(attemptId: wire(attemptID)))
            if let suffix = tracker.advance(attemptID, to: accumulatedText(message)) {
              yieldEvent(continuation, .delta(attemptId: wire(attemptID), text: suffix))
            }
          }
          for await event in live {
            switch event {
            case let .started(attemptID):
              guard tracker.start(attemptID) else { continue }
              yieldEvent(continuation, .started(attemptId: wire(attemptID)))
            case let .delta(attemptID, inference):
              if tracker.start(attemptID) {
                yieldEvent(continuation, .started(attemptId: wire(attemptID)))
              }
              if let suffix = tracker.advance(attemptID, to: accumulatedText(inference.partialMessage)) {
                yieldEvent(continuation, .delta(attemptId: wire(attemptID), text: suffix))
              }
            case let .finished(attemptID, outcome):
              switch outcome {
              case .done:
                // Not materialized yet: that event rides the committed-entry
                // stream below, strictly after the durable commit.
                break
              case let .failed(reason):
                tracker.drop(attemptID)
                yieldEvent(continuation, .cancelled(attemptId: wire(attemptID), reason: reason))
              }
            }
          }
          return false
        }
        group.addTask {
          do {
            for try await page in store.observeTranscript(session, from: cursor, bounded: bounded, historyEpoch: historyEpoch) {
              if page.reset {
                yieldEvent(continuation, .reset(generation: page.generation))
                if bounded { break }
              }
              for (offset, item) in page.items.enumerated() {
                if case let .assistant(entry) = item, tracker.claimCommitted(entry.id) {
                  yieldEvent(continuation, .materialized(attemptId: wire(entry.id), entryId: wire(entry.id)))
                }
                yieldEvent(continuation, .item(
                  generation: page.generation,
                  position: page.startPosition + offset,
                  item: itemJSON(item),
                ))
              }
            }
          } catch {}
          // The committed stream is the authority: when it ends, end the
          // response instead of dangling on attempt events alone.
          continuation.finish()
          return true
        }
        while let ended = await group.next() {
          if ended { group.cancelAll(); break }
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
  return .sse(events)
}

private func yieldEvent(_ continuation: AsyncStream<SSEEvent>.Continuation, _ event: SessionStreamEvent) {
  if let encoded = try? SSEEvent.json(event) {
    continuation.yield(encoded)
  }
}

private func wire(_ id: UUID) -> String {
  id.uuidString.lowercased()
}

// The wire item is the session domain's canonical Codable encoding, carried as
// an opaque JSON leaf (see SPEC.md "Session direct view").
func itemJSON(_ item: TranscriptItem) -> JSONValue {
  guard let data = try? JSONEncoder().encode(item),
        let value = JSONValue.parse(String(decoding: data, as: UTF8.self))
  else { return .null }
  return value
}

private func accumulatedText(_ message: AssistantMessage) -> String {
  message.content.compactMap { block -> String? in
    guard case let .text(text) = block else { return nil }
    return text.text
  }.joined(separator: "\n\n")
}

// Per-connection attempt bookkeeping: which attempts this stream announced,
// and how much of each accumulated text it already sent (deltas are suffixes
// of a monotonically growing accumulation, so cursor math is gap/dupe-free).
private final class AttemptTracker: Sendable {
  private struct State {
    var announced: Set<UUID> = []
    var sent: [UUID: Int] = [:]
  }

  private let state = Mutex(State())

  func start(_ id: UUID) -> Bool {
    state.withLock { $0.announced.insert(id).inserted }
  }

  func advance(_ id: UUID, to accumulated: String) -> String? {
    state.withLock { state in
      let already = state.sent[id] ?? 0
      guard accumulated.count > already else { return nil }
      state.sent[id] = accumulated.count
      return String(accumulated.dropFirst(already))
    }
  }

  func drop(_ id: UUID) {
    state.withLock { state in
      state.announced.remove(id)
      state.sent[id] = nil
    }
  }

  func claimCommitted(_ id: UUID) -> Bool {
    state.withLock { state in
      guard state.announced.contains(id) else { return false }
      state.announced.remove(id)
      state.sent[id] = nil
      return true
    }
  }
}
