import struct FetchSSE.SSEEvent
import struct FetchSSE.SSEEvents
import JSONValue
import struct MainHub.EventSources
import enum MainHub.StreamFailure
import SessionDomain
import enum SpaceCore.SubscriptionOwner
import StructuredQueries
import WuweiNeo
import WuweiNeoQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A stream observation as a job: it dials `url` as `dialer`, resuming after the last event its owner acked, and sends the owner one event at a time, the next only after `acked`. A dropped stream is dialled again, backing off from 1 s to 5 min, or longer when its server says so; a refused one ends the job with a last message. `stop` ends it.
@Job
struct StreamJob {
  static let schema = [
    """
    CREATE TABLE streams (\(ownerColumn), session_id TEXT, subscription_id TEXT NOT NULL, url TEXT NOT NULL,
      armed_at TEXT NOT NULL, last_event_id TEXT NOT NULL DEFAULT '', UNIQUE (owner))
    """,
  ]

  struct Params: Codable {
    let dialer: SubscriptionOwner
    /// The session whose plain stream it is, as its subscriptions list it; nil for an observer cell's.
    let session: SessionID?
    let subscription: SubscriptionID
    let url: URL
    let throttle: Double
    let owner: Recipient<Streamed>
  }

  enum Message: Codable, Equatable {
    case acked
    case stop
  }

  static func create(ctx: inout JobContext<Self>) throws {
    let params = ctx.params
    let row = StreamRow(sessionID: params.session?.rawValue, subscriptionID: params.subscription.rawValue, url: params.url.absoluteString, armedAt: Date(ctx.now).formatted(queueDate))
    try ctx.db.execute(StreamRow.insert { row })
  }

  mutating func start() async throws -> Outcome {
    guard let row = db.rows(StreamRow.all).first else { return .done }
    let params = ctx.params
    let reader = EventReader(url: params.url, dialer: params.dialer, after: row.lastEventID, sources: ctx.dependency(LoopClient.self).config.sources)
    var backoff = 0
    while true {
      var retryAfter = Duration.zero
      do {
        reading: while true {
          switch try await ctx.race({ _, _ in try await reader.next() }, until: { $0 == .stop }) {
          case .message:
            return try stop()
          case .finished(nil):
            break reading
          case let .finished(event?):
            backoff = 0
            ctx.send(.streamed(batch(event: StreamedEvent(event))), to: params.owner)
            guard try await acked() else { return try stop() }
            let id = event.id ?? ""
            try db.execute(StreamRow.update { $0.lastEventID = #bind(id) })
          }
        }
      } catch let StreamFailure.refused(reason) {
        try db.execute(StreamRow.delete())
        let ending = "observation \(params.subscription.rawValue) of \(params.url) failed and was cancelled: \(reason)"
        return .done(sending: .streamed(batch(ending: ending)), to: params.owner)
      } catch let StreamFailure.unavailable(after) {
        retryAfter = after ?? .zero
      } catch is CancellationError {
        throw CancellationError()
      } catch {}
      await reader.close()
      backoff = min(max(1, backoff * 2), 300)
      if try await ctx.receive(within: max(.seconds(backoff), retryAfter)) == .stop { return try stop() }
    }
  }

  /// Whether the owner took the event: false when it said `stop` instead.
  private func acked() async throws -> Bool {
    while true {
      switch try await ctx.receive(within: .seconds(3600)) {
      case .acked?: return true
      case .stop?: return false
      case nil: continue
      }
    }
  }

  private mutating func stop() throws -> Outcome {
    try db.execute(StreamRow.delete())
    return .done
  }

  private func batch(event: StreamedEvent? = nil, ending: String? = nil) -> StreamBatch {
    let params = ctx.params
    return StreamBatch(job: id, subscription: params.subscription, url: params.url, throttle: params.throttle, event: event, ending: ending)
  }
}

/// What a stream job says to its owner, whose messages must include this case.
enum Streamed: Codable, Sendable {
  case streamed(StreamBatch)
}

struct StreamBatch: Codable, Sendable {
  let job: StreamJob.ID
  let subscription: SubscriptionID
  let url: URL
  let throttle: Double
  /// One event, or, at the end, why the stream ended.
  let event: StreamedEvent?
  let ending: String?

  /// The event as it came over the wire, or why the stream ended.
  var text: String { ending ?? event!.rendered }
}

struct StreamedEvent: Codable, Sendable {
  let id: String?
  let type: String
  let data: String

  init(_ event: SSEEvent) {
    (id, type, data) = (event.id, event.event, event.data)
  }

  /// A handler's input: `{event: {id, type, data}}`.
  var handlerInput: JSONValue {
    .object(["event": .object(["id": id.map(JSONValue.string) ?? .null, "type": .string(type), "data": .string(data)])])
  }

  /// As it came over the wire, cut at 64 KiB.
  var rendered: String {
    var lines = id.map { ["id: " + $0] } ?? []
    if type != "message" { lines.append("event: " + type) }
    lines += data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: " + $0 }
    let wire = lines.joined(separator: "\n") + "\n\n"
    let size = wire.utf8.count
    return size <= eventLimit ? wire : String(decoding: wire.utf8.prefix(eventLimit), as: UTF8.self) + "\n(cut at 64 KiB of \(size) bytes)\n\n"
  }
}

/// One connection at a time, kept across the races that read it.
private actor EventReader {
  let url: URL
  let dialer: SubscriptionOwner
  var after: String
  let sources: EventSources
  var events: SSEEvents.AsyncIterator?

  init(url: URL, dialer: SubscriptionOwner, after: String, sources: EventSources) {
    self.url = url
    self.dialer = dialer
    self.after = after
    self.sources = sources
  }

  /// The next event, dialling first when no connection is open; nil when the connection ends.
  func next() async throws -> SSEEvent? {
    var iterator: SSEEvents.AsyncIterator
    if let events {
      iterator = events
    } else {
      iterator = try await sources.open(url, as: dialer, after: after).makeAsyncIterator()
    }
    events = nil
    guard let event = try await iterator.next(isolation: self) else { return nil }
    after = event.id ?? ""
    events = iterator
    return event
  }

  func close() {
    events = nil
  }
}

private let eventLimit = 64 << 10

@Table("streams")
struct StreamRow: Owned {
  @Column("session_id") let sessionID: String?
  @Column("subscription_id") let subscriptionID: String
  let url: String
  @Column("armed_at") let armedAt: String
  @Column("last_event_id") var lastEventID = ""
}
