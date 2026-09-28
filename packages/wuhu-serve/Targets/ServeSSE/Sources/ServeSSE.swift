#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import Serve

public struct SSEEvent: Sendable, Equatable {
  public var event: String?
  public var id: String?
  public var retry: Int?
  public var data: [String]
  public var comment: [String]

  public init(
    event: String? = nil,
    id: String? = nil,
    retry: Int? = nil,
    data: [String] = [],
    comment: [String] = [],
  ) {
    self.event = event
    self.id = id
    self.retry = retry
    self.data = data
    self.comment = comment
  }

  public static func message(
    _ string: String,
    event: String? = nil,
    id: String? = nil,
    retry: Int? = nil,
  ) -> Self {
    Self(
      event: event,
      id: id,
      retry: retry,
      data: sseLines(for: string),
    )
  }

  public static func comment(_ string: String = "") -> Self {
    Self(comment: sseLines(for: string))
  }

  public static func json<T: Encodable>(
    _ value: T,
    event: String? = nil,
    id: String? = nil,
    retry: Int? = nil,
    outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys],
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .secondsSince1970,
  ) throws -> Self {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    encoder.dateEncodingStrategy = dateEncodingStrategy
    let data = try encoder.encode(value)
    return .message(
      String(decoding: data, as: UTF8.self),
      event: event,
      id: id,
      retry: retry,
    )
  }

  public var bytes: Bytes {
    Data(self.serialized.utf8)
  }

  public var serialized: String {
    var lines: [String] = []

    for comment in self.comment {
      lines.append(comment.isEmpty ? ":" : ": \(comment)")
    }

    if let event = self.event {
      lines.append("event: \(event)")
    }

    if let id = self.id {
      lines.append("id: \(id)")
    }

    if let retry = self.retry {
      lines.append("retry: \(retry)")
    }

    for dataLine in self.data {
      lines.append("data: \(dataLine)")
    }

    return lines.joined(separator: "\n") + "\n\n"
  }
}

extension Response {
  /// A server-sent-event response that forwards a live source, owning the
  /// connection-bound lifecycle every observe/subscribe route needs.
  ///
  /// Routes used to hand-roll the identical body verbatim — an `AsyncStream`
  /// whose `continuation` drives a `Task` that seeds an optional initial frame,
  /// loops the source iterator with a `Task.isCancelled` break and an
  /// encode-failure break, `finish()`es, and cancels the task on
  /// `onTermination` so a client disconnect tears down the upstream
  /// subscription. That copy lived at five sites and any cancellation/ordering
  /// fix had to be applied to each. This is the single combinator they share.
  ///
  /// The caller still owns the **load-bearing ordering**: it must subscribe to
  /// `source` *before* taking the cold snapshot it passes as `initial`, so a
  /// delta landing between the snapshot and the stream opening is buffered, not
  /// lost (the subscribe-before-cold-read invariant). This combinator only owns
  /// the forwarding lifecycle, not the subscription ordering.
  ///
  /// - Parameters:
  ///   - initial: An already-encoded frame to seed the stream with (the cold
  ///     snapshot), or `nil` for sources that carry no initial frame.
  ///   - source: The live delta source. May be throwing; a thrown error ends the
  ///     stream best-effort (clients reconnect), matching the prior inline
  ///     `do/catch` that swallowed the error.
  ///   - encode: Maps each delta to its wire frame. Returning `nil` ends the
  ///     stream, preserving the prior `guard let event = try? … else { break }`.
  public static func sse<Source: AsyncSequence & Sendable>(
    initial: SSEEvent? = nil,
    forwarding source: Source,
    status: Status = .ok,
    headers: Headers = Headers(),
    heartbeat: Duration? = .seconds(15),
    clock: any Clock<Duration> = ContinuousClock(),
    encode: @escaping @Sendable (Source.Element) async -> SSEEvent?,
  ) -> Self where Source.Element: Sendable {
    let events = AsyncStream<SSEEvent> { continuation in
      let task = Task {
        if let initial { continuation.yield(initial) }
        do {
          for try await element in source {
            if Task.isCancelled { break }
            guard let event = await encode(element) else { break }
            continuation.yield(event)
          }
        } catch {
          // Best-effort: a source error ends the stream; clients reconnect.
        }
        continuation.finish()
      }
      // Bound the stream to the client connection: tearing down the body stream
      // (client disconnect) cancels the forwarding task, which cancels the
      // source iterator and unregisters this consumer. No leaked task.
      continuation.onTermination = { _ in task.cancel() }
    }
    return sse(events, status: status, headers: headers, heartbeat: heartbeat, clock: clock)
  }

  public static func sse<S: AsyncSequence & Sendable>(
    _ events: S,
    status: Status = .ok,
    headers: Headers = Headers(),
    heartbeat: Duration? = .seconds(15),
    clock: any Clock<Duration> = ContinuousClock(),
  ) -> Self where S.Element == SSEEvent {
    var responseHeaders = headers
    if responseHeaders[.contentType] == nil {
      responseHeaders[.contentType] = "text/event-stream; charset=utf-8"
    }
    if responseHeaders[.cacheControl] == nil {
      responseHeaders[.cacheControl] = "no-cache"
    }
    if responseHeaders[sseXAccelBufferingHeaderName] == nil {
      responseHeaders[sseXAccelBufferingHeaderName] = "no"
    }

    return Self(
      status: status,
      headers: responseHeaders,
      body: .stream(
        contentType: responseHeaders[.contentType],
        SSEBodySequence(base: keptAlive(events, heartbeat: heartbeat, clock: clock)),
      ),
    )
  }

  // The preamble comment gives a buffering intermediary (node http-proxy, an
  // unconfigured nginx) a first body chunk so the response head leaves
  // immediately — a header-only SSE response otherwise sits in the proxy until
  // the first event. The heartbeat keeps flowing so both sides can tell a
  // quiet stream from a dead connection: a failed write tears down the
  // upstream subscription, and clients may treat prolonged byte silence as a
  // reason to reconnect. Comments are invisible to conformant SSE parsers.
  private static func keptAlive<S: AsyncSequence & Sendable>(
    _ events: S,
    heartbeat: Duration?,
    clock: any Clock<Duration>,
  ) -> AsyncStream<SSEEvent> where S.Element == SSEEvent {
    AsyncStream { continuation in
      let task = Task {
        continuation.yield(.comment())
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            do {
              for try await event in events {
                if Task.isCancelled { break }
                continuation.yield(event)
              }
            } catch {
              // Best-effort: a source error ends the stream; clients reconnect.
            }
          }
          if let heartbeat {
            group.addTask {
              while !Task.isCancelled {
                guard (try? await clock.sleep(for: heartbeat)) != nil else { break }
                continuation.yield(.comment())
              }
            }
          }
          // The source ending must end the response even while the heartbeat
          // child would keep the group alive.
          await group.next()
          group.cancelAll()
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// A single-shot `AsyncSequence` that hands back an iterator the caller has
/// *already* created — for sources whose subscription must register before a
/// cold snapshot is read (the subscribe-before-read invariant). The combinator's
/// `Response.sse(initial:forwarding:encode:)` makes the iterator inside its Task,
/// which is too late for those sources; wrapping the pre-made iterator preserves
/// the registration ordering while still flowing through the shared combinator.
///
/// Single-shot: `makeAsyncIterator` may be called only once (the combinator does
/// exactly that), since an iterator cannot be duplicated.
public struct PreparedAsyncSequence<Iterator: AsyncIteratorProtocol & Sendable>: AsyncSequence, Sendable {
  public typealias Element = Iterator.Element

  private let iterator: Iterator

  public init(_ iterator: Iterator) {
    self.iterator = iterator
  }

  public func makeAsyncIterator() -> Iterator {
    iterator
  }
}

public let sseXAccelBufferingHeaderName: HTTPField.Name = HTTPField.Name("x-accel-buffering")!

private struct SSEBodySequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
  where Base.Element == SSEEvent
{
  typealias Element = Bytes

  let base: Base

  func makeAsyncIterator() -> Iterator {
    Iterator(base: self.base.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: Base.AsyncIterator

    mutating func next() async throws -> Bytes? {
      guard let event = try await self.base.next() else {
        return nil
      }
      return event.bytes
    }
  }
}

private func sseLines(for string: String) -> [String] {
  string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}
