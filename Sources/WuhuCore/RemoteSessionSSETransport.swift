import Foundation
import PiAI

/// Remote transport that speaks the session contracts over HTTP + SSE.
///
/// This is the adapter WuhuApp should use: it conforms to
/// ``SessionCommanding`` and ``SessionSubscribing`` but talks to a
/// Wuhu server's SSE endpoint.
public actor RemoteSessionSSETransport: SessionCommanding, SessionSubscribing {
  public struct RetryPolicy: Sendable, Hashable {
    public var maxDelaySeconds: Double

    public init(maxDelaySeconds: Double = 30) {
      self.maxDelaySeconds = maxDelaySeconds
    }

    /// Exponential backoff with an immediate first retry:
    /// 0s, 1s, 2s, 4s, ... capped.
    public func delaySeconds(forAttempt attempt: Int) -> Double {
      guard attempt > 0 else { return 0 }
      if attempt == 1 { return 0 }
      return min(pow(2.0, Double(attempt - 2)), maxDelaySeconds)
    }
  }

  public typealias Sleeper = @Sendable (_ seconds: Double) async throws -> Void

  public var baseURL: URL
  private let http: any HTTPClient
  private let retryPolicy: RetryPolicy
  private let sleep: Sleeper

  public init(
    baseURL: URL,
    http: any HTTPClient = AsyncHTTPClientTransport(),
    retryPolicy: RetryPolicy = RetryPolicy(),
    sleep: @escaping Sleeper = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
  ) {
    self.baseURL = baseURL
    self.http = http
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  public func enqueue(sessionID: SessionID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    let url = baseURL
      .appending(path: "v3")
      .appending(path: "sessions")
      .appending(path: sessionID.rawValue)
      .appending(path: "enqueue")

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "lane", value: lane.rawValue)]

    var req = HTTPRequest(url: components?.url ?? url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(message)

    let (data, _) = try await http.data(for: req)
    return try WuhuJSON.decoder.decode(QueueItemID.self, from: data)
  }

  public func cancel(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws {
    struct CancelBody: Codable, Sendable { var id: QueueItemID }

    let url = baseURL
      .appending(path: "v3")
      .appending(path: "sessions")
      .appending(path: sessionID.rawValue)
      .appending(path: "cancel")

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "lane", value: lane.rawValue)]

    var req = HTTPRequest(url: components?.url ?? url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.body = try WuhuJSON.encoder.encode(CancelBody(id: id))

    _ = try await http.data(for: req)
  }

  public func subscribe(sessionID: SessionID, since request0: SessionSubscriptionRequest) async throws -> SessionSubscription {
    let (events, eventsContinuation) = AsyncThrowingStream<SessionEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingNewest(4096),
    )

    let (connectionStates, connectionContinuation) = AsyncStream<SessionSubscriptionConnectionState>.makeStream(
      bufferingPolicy: .bufferingNewest(64),
    )

    let (initialStream, initialContinuation) = AsyncThrowingStream<SessionInitialState, any Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )

    connectionContinuation.yield(.connecting)

    let task = Task {
      var didFinishInitial = false
      var request = request0
      var attempt = 0

      defer {
        if !didFinishInitial {
          initialContinuation.finish(throwing: CancellationError())
        }
        eventsContinuation.finish()
        connectionContinuation.yield(.closed)
        connectionContinuation.finish()
      }

      while !Task.isCancelled {
        do {
          let sse = try await http.sse(for: makeSubscribeRequest(sessionID: sessionID, request: request))

          attempt = 0
          connectionContinuation.yield(.connected)

          for try await message in sse {
            try Task.checkCancellation()
            guard let data = message.data.data(using: .utf8) else { continue }

            let frame = try WuhuJSON.decoder.decode(SessionSubscriptionSSEFrame.self, from: data)

            switch frame {
            case let .initial(state):
              request = advanceSince(afterInitial: state, fallback: request)

              if !didFinishInitial {
                didFinishInitial = true
                initialContinuation.yield(state)
                initialContinuation.finish()
                continue
              }

              if !state.transcriptPages.isEmpty {
                for page in state.transcriptPages {
                  eventsContinuation.yield(.transcriptAppended(page))
                }
              }

              if !state.systemUrgent.journal.isEmpty {
                eventsContinuation.yield(.systemUrgentQueue(cursor: state.systemUrgent.cursor, entries: state.systemUrgent.journal))
              }

              if !state.steer.journal.isEmpty {
                eventsContinuation.yield(.userQueue(cursor: state.steer.cursor, entries: state.steer.journal))
              }

              if !state.followUp.journal.isEmpty {
                eventsContinuation.yield(.userQueue(cursor: state.followUp.cursor, entries: state.followUp.journal))
              }

              eventsContinuation.yield(.settingsUpdated(state.settings))
              eventsContinuation.yield(.statusUpdated(state.status))

            case let .event(event):
              guard didFinishInitial else {
                continue
              }
              request = advanceSince(afterEvent: event, fallback: request)
              eventsContinuation.yield(event)
            }
          }

          throw RemoteSessionSSETransportError.streamEnded
        } catch {
          if Task.isCancelled { return }

          if !isRetryable(error) {
            if !didFinishInitial {
              didFinishInitial = true
              initialContinuation.finish(throwing: error)
            } else {
              eventsContinuation.finish(throwing: error)
            }
            return
          }

          let nextAttempt = attempt + 1
          let delay = retryPolicy.delaySeconds(forAttempt: nextAttempt)
          connectionContinuation.yield(.retrying(attempt: nextAttempt, delaySeconds: delay))

          attempt = nextAttempt

          if delay > 0 {
            try? await sleep(delay)
          }

          connectionContinuation.yield(.connecting)
          continue
        }
      }
    }

    eventsContinuation.onTermination = { _ in
      task.cancel()
    }
    connectionContinuation.onTermination = { _ in
      task.cancel()
    }
    initialContinuation.onTermination = { termination in
      if case .cancelled = termination {
        task.cancel()
      }
    }

    var it = initialStream.makeAsyncIterator()
    guard let initial = try await it.next() else {
      throw CancellationError()
    }

    return .init(initial: initial, events: events, connectionStates: connectionStates)
  }

  private func makeSubscribeRequest(sessionID: SessionID, request: SessionSubscriptionRequest) -> HTTPRequest {
    var url = baseURL
      .appending(path: "v3")
      .appending(path: "sessions")
      .appending(path: sessionID.rawValue)
      .appending(path: "subscribe")

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []

    if let transcriptSince = request.transcriptSince?.rawValue, !transcriptSince.isEmpty {
      items.append(.init(name: "transcriptSince", value: transcriptSince))
    }
    items.append(.init(name: "transcriptPageSize", value: String(request.transcriptPageSize)))

    if let systemSince = request.systemSince?.rawValue, !systemSince.isEmpty {
      items.append(.init(name: "systemSince", value: systemSince))
    }
    if let steerSince = request.steerSince?.rawValue, !steerSince.isEmpty {
      items.append(.init(name: "steerSince", value: steerSince))
    }
    if let followUpSince = request.followUpSince?.rawValue, !followUpSince.isEmpty {
      items.append(.init(name: "followUpSince", value: followUpSince))
    }

    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    var req = HTTPRequest(url: url, method: "GET")
    req.setHeader("text/event-stream", for: "Accept")
    return req
  }

  private func advanceSince(afterInitial initial: SessionInitialState, fallback: SessionSubscriptionRequest) -> SessionSubscriptionRequest {
    let lastItemID = initial.transcriptPages.last?.items.last?.id.rawValue
    let transcriptSince = lastItemID.map(TranscriptCursor.init(rawValue:)) ?? fallback.transcriptSince

    return SessionSubscriptionRequest(
      transcriptSince: transcriptSince,
      transcriptPageSize: fallback.transcriptPageSize,
      systemSince: initial.systemUrgent.cursor,
      steerSince: initial.steer.cursor,
      followUpSince: initial.followUp.cursor,
    )
  }

  private func advanceSince(afterEvent event: SessionEvent, fallback: SessionSubscriptionRequest) -> SessionSubscriptionRequest {
    var next = fallback

    switch event {
    case let .transcriptAppended(page):
      if let id = page.items.last?.id.rawValue {
        next.transcriptSince = .init(rawValue: id)
      }

    case let .systemUrgentQueue(cursor, entries: _):
      next.systemSince = cursor

    case let .userQueue(cursor, entries):
      guard let lane = entries.first?.lane else { break }
      switch lane {
      case .steer:
        next.steerSince = cursor
      case .followUp:
        next.followUpSince = cursor
      }

    case .settingsUpdated, .statusUpdated:
      break
    }

    return next
  }

  private func isRetryable(_ error: any Error) -> Bool {
    if error is CancellationError { return false }
    if error is DecodingError { return false }
    if error is RemoteSessionSSETransportError { return true }

    return true
  }
}

public enum RemoteSessionSSETransportError: Error, Sendable, Equatable {
  case missingInitialFrame
  case streamEnded
}

/// Wire format for `GET /v3/sessions/:id/subscribe`.
public enum SessionSubscriptionSSEFrame: Sendable, Hashable, Codable {
  case initial(SessionInitialState)
  case event(SessionEvent)
}
