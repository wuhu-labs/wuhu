import Dependencies
import Fetch
import FetchSSE
import Foundation
import JSONValue
import OrderedCollections
import Synchronization

// MARK: - Cross-provider context normalization

/// Rewrite a request context into provider-safe wire form before building:
/// normalize tool-call IDs and drop reasoning signatures foreign to the
/// target provider. Applied by every dialect endpoint before serialization.
func normalizedRequestContext(_ context: Context, targetProviderID: String) -> Context {
  var context = context
  normalizeToolCallIDs(in: &context.messages)
  normalizeReasoningForTarget(in: &context.messages, targetProviderID: targetProviderID)
  normalizeHostedToolsForTarget(in: &context.messages, targetProviderID: targetProviderID)
  return context
}

// MARK: - Shared SSE inference transport

/// The single streaming engine shared by every dialect: build the request,
/// fetch, parse the SSE into ``InferenceEvent``s, and report everything as a
/// cold `AsyncStream<Result<…>>`.
///
/// Failures are reported in-band as `.failure` (never thrown across the
/// boundary). Cancelling the consuming task cancels the request via the
/// stream's `onTermination` and finishes without a terminal event.
func runSSEInference(
  buildRequest: @escaping @Sendable () async throws -> (url: URL, headers: [String: String], body: OrderedDictionary<String, JSONValue>),
  modifyBody: @escaping @Sendable (inout OrderedDictionary<String, JSONValue>, RequestOptions) -> Void,
  modifyHeaders: @escaping @Sendable (inout RequestHeaders, RequestOptions) -> Void,
  receiveResponseHeaders: @escaping @Sendable ([String: String]) async -> Void = { _ in },
  options: RequestOptions,
  parse: @escaping @Sendable (AsyncThrowingStream<SSEEvent, any Error>) -> AsyncThrowingStream<InferenceEvent, any Error>,
) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
  // Capture the ambient dependencies synchronously, before the producer task
  // starts, so a `withDependencies { … }` scope (record/replay, custom
  // transports, test clocks) is honored.
  @Dependency(\.fetch) var fetch
  @Dependency(\.continuousClock) var ambientClock
  let fetchClient = fetch
  let clock = ambientClock

  return AsyncStream { continuation in
    let task = Task {
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          let activity = IdleActivity()
          if let idleTimeout = options.idleTimeout {
            group.addTask {
              var seen = activity.generation
              while true {
                try await clock.sleep(for: idleTimeout)
                let current = activity.generation
                guard current != seen else { throw IdleTimeoutExceeded() }
                seen = current
              }
            }
          }
          group.addTask {
            let (url, rawHeaders, requestBody) = try await buildRequest()
            var body = requestBody
            modifyBody(&body, options)
            var headers = RequestHeaders(values: rawHeaders)
            modifyHeaders(&headers, options)

            let request = Request(
              url: url,
              method: .post,
              headers: headers,
              body: .string(JSONValue.object(body).jsonString(), encoding: .utf8),
            )

            let response = try await fetchClient.fetch(request)
            activity.touch()
            await receiveResponseHeaders(RequestHeaders(response.headers).values)
            guard (200 ..< 300).contains(response.status.code) else {
              let body = try? await response.body.text(upTo: 64 * 1024)
              continuation.yield(.failure(InferenceError.classify(
                status: response.status.code,
                headers: response.headers,
                body: body,
              )))
              return
            }

            for try await event in parse(response.sse().mapWuhuAIEvents()) {
              activity.touch()
              continuation.yield(.success(event))
            }
          }
          try await group.next()
          group.cancelAll()
        }
        continuation.finish()
      } catch is CancellationError {
        continuation.finish()
      } catch is IdleTimeoutExceeded {
        continuation.yield(.failure(.transport(.idleTimeout)))
        continuation.finish()
      } catch {
        continuation.yield(.failure(InferenceError.normalize(error)))
        continuation.finish()
      }
    }

    continuation.onTermination = { _ in task.cancel() }
  }
}

private struct IdleTimeoutExceeded: Error {}

// The watchdog compares generations across a full sleep instead of tracking
// instants: it fires only after a window with zero activity, at the cost of
// firing up to one window late when activity lands mid-sleep.
private final class IdleActivity: Sendable {
  private let counter = Mutex(0)

  var generation: Int { counter.withLock { $0 } }
  func touch() { counter.withLock { $0 += 1 } }
}

// MARK: - SSE Bridging

extension AsyncThrowingStream where Element == FetchSSE.SSEEvent, Failure == any Error {
  func mapWuhuAIEvents() -> AsyncThrowingStream<WuhuAI.SSEEvent, any Error> {
    AsyncThrowingStream<WuhuAI.SSEEvent, any Error> { continuation in
      let task = Task {
        do {
          for try await event in self {
            continuation.yield(WuhuAI.SSEEvent(
              event: event.event,
              data: event.data,
              id: event.id,
              retry: event.retry,
            ))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
