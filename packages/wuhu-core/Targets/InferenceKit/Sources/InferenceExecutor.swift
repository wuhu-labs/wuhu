import Clocks
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Logging
import SessionDomain
import WuhuAI

public struct CompletedInference: Sendable {
  public var message: AssistantMessage
  public var metadata: AssistantMessageMetadata
  public var context: Context

  public init(message: AssistantMessage, metadata: AssistantMessageMetadata, context: Context) {
    self.message = message
    self.metadata = metadata
    self.context = context
  }
}

public struct InferenceCancelled: Error, Equatable, Sendable {}

public struct InferenceExecutor: Sendable {
  public var session: SessionID
  public var model: ResolvedModel
  public var systemPrompt: String
  public var opening: [String]
  public var tools: [Tool]
  public var trace: AttemptTraceClient?
  public var metrics: InferenceMetricsSink
  public var webSocket: ResponsesWebSocketSession?
  public var receiveQuota: @Sendable (JSONValue) async -> Void
  public var mediaResolver: (any MediaResolver)?

  public init(
    session: SessionID,
    model: ResolvedModel,
    systemPrompt: String,
    opening: [String] = [],
    tools: [Tool],
    trace: AttemptTraceClient? = nil,
    metrics: InferenceMetricsSink = .noop,
    webSocket: ResponsesWebSocketSession? = nil,
    receiveQuota: @escaping @Sendable (JSONValue) async -> Void = { _ in },
    mediaResolver: (any MediaResolver)? = nil,
  ) {
    self.session = session
    self.model = model
    self.systemPrompt = systemPrompt
    self.opening = opening
    self.tools = tools
    self.trace = trace
    self.metrics = metrics
    self.mediaResolver = mediaResolver
    self.webSocket = webSocket
    self.receiveQuota = receiveQuota
  }

  public func run(
    attemptID: UUID,
    lines: [TranscriptLine],
    idleTimeout: Duration? = nil,
  ) async throws -> CompletedInference {
    let context = Context(systemPrompt: systemPrompt, messages: opening.map { .user(.init(content: [.text($0)])) } + lines.map(\.message), tools: tools)
    let options = RequestOptions(
      maxTokens: model.budget.maxOutput,
      reasoning: reasoning(for: lines),
      idleTimeout: idleTimeout,
    )

    let sizes = TrafficSizes()
    var endpoint: any ModelEndpoint = model.endpoint
    if model.transport == .websocket {
      guard let webSocket, let responses = endpoint as? any ResponsesEndpoint else {
        throw InferenceError.invalidInput(status: 422, body: "WebSocket transport has no runtime session")
      }
      endpoint = responses.withWebSocket(session: webSocket, attemptID: attemptID.uuidString, observer: socketAttemptObserver(trace: try await trace?.open(attemptID), sizes: sizes), receiveQuota: receiveQuota)
    } else if let trace {
      @Dependency(\.fetch) var fetch
      endpoint = endpoint.withFetch(attemptLoggingFetch(
        base: fetch,
        trace: trace,
        attemptID: attemptID,
        sizes: sizes,
      ))
    }
    if let mediaResolver {
      endpoint = endpoint.withMediaResolver(mediaResolver)
    }

    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.date) var dateGen

    let timestamp = dateGen.now
    var completed: CompletedInference?
    var failure: InferenceError?
    var reportedUsage: Usage?
    var servedModel: String?
    var firstEventSeen = false

    func handle(_ result: Result<InferenceEvent, InferenceError>) async throws {
      switch result {
      case let .success(event):
        if case let .usage(usage, reportedModel, _) = event {
          reportedUsage = usage
          servedModel = reportedModel
        }
        if case let .done(message, metadata) = event {
          completed = CompletedInference(message: message, metadata: metadata, context: context)
        }
      case let .failure(error):
        failure = error
      }
    }

    let clock = AnyClock(continuousClock)
    let started = clock.now
    var ttftDuration: Duration?
    do {
      var iterator = endpoint.runInference(context: context, options: options, mediaResolver: nil).makeAsyncIterator()
      let firstResult = await iterator.next()
      ttftDuration = started.duration(to: clock.now)
      if let firstResult {
        if case .success = firstResult { firstEventSeen = true }
        try await handle(firstResult)
      }
      while failure == nil, let result = await iterator.next() {
        try await handle(result)
      }
    } catch { failure = InferenceError.normalize(error) }
    let elapsed = started.duration(to: clock.now)
    let ttft = firstEventSeen ? ttftDuration : nil

    if let failure {
      logAttempt(attemptID: attemptID, sizes: sizes, status: "failed(\(failure))", usage: nil, elapsed: elapsed)
      await metrics.record(metric(timestamp: timestamp, error: failure, cancelled: false, usage: reportedUsage, servedModel: servedModel, ttft: ttft, elapsed: elapsed))
      throw failure
    }
    guard let completed else {
      logAttempt(attemptID: attemptID, sizes: sizes, status: "cancelled", usage: nil, elapsed: elapsed)
      await metrics.record(metric(timestamp: timestamp, error: nil, cancelled: true, usage: reportedUsage, servedModel: servedModel, ttft: ttft, elapsed: elapsed))
      throw InferenceCancelled()
    }
    logAttempt(
      attemptID: attemptID,
      sizes: sizes,
      status: "done(\(completed.metadata.stopReason.rawValue))",
      usage: completed.metadata.usage,
      elapsed: elapsed,
    )
    await metrics.record(metric(timestamp: timestamp, error: nil, cancelled: false, usage: completed.metadata.usage, servedModel: completed.metadata.servedModel, ttft: ttft, elapsed: elapsed))
    return completed
  }

  public func acknowledge(entry: AssistantEntry, context: Context) async {
    guard let webSocket, model.transport == .websocket else { return }
    var context = context
    context.messages.append(.assistant(.init(content: entry.content)))
    await webSocket.acknowledge(attemptID: entry.id.uuidString, committedMessage: .init(content: entry.content), toolCallIDs: entry.toolCallIDs.mapValues(\.rawValue), renderedContext: context)
  }

  private func metric(
    timestamp: Date,
    error: InferenceError?,
    cancelled: Bool,
    usage: Usage?,
    servedModel: String? = nil,
    ttft: Duration?,
    elapsed: Duration,
  ) -> InferenceMetric {
    let derived = cancelled ? (outcome: InferenceMetric.Outcome.cancelled, kind: String?.none, status: Int?.none, text: String?.none) : InferenceMetric.classify(error)
    return InferenceMetric(
      timestamp: timestamp,
      payer: .session(session),
      provider: model.specifier.provider,
      model: model.specifier.model,
      servedModel: servedModel,
      effort: model.specifier.effort,
      outcome: derived.outcome,
      errorKind: derived.kind,
      errorText: derived.text,
      status: derived.status,
      ttftMs: ttft?.milliseconds,
      durationMs: elapsed.milliseconds,
      usage: usage,
    )
  }

  private func logAttempt(
    attemptID: UUID,
    sizes: TrafficSizes,
    status: String,
    usage: Usage?,
    elapsed: Duration,
  ) {
    guard trace != nil else { return }
    let logger = Logger(label: "wuhu.inference")
    logger.info("inference attempt", metadata: [
      "attempt": "\(attemptID.uuidString.lowercased())",
      "session": "\(session.rawValue)",
      "provider": "\(model.specifier.provider)",
      "model": "\(model.specifier.model)",
      "effort": "\(model.specifier.effort)",
      "status": "\(status)",
      "request_bytes": "\(sizes.request)",
      "response_bytes": "\(sizes.response)",
      "usage": "\(usage.map(describe) ?? "none")",
      "latency_ms": "\(elapsed.milliseconds)",
    ])
  }
}

private func describe(_ usage: Usage) -> String {
  "in=\(usage.inputTokens) out=\(usage.outputTokens) cacheRead=\(usage.cacheReadTokens) "
    + "cacheWrite=\(usage.cacheWriteTokens) reasoning=\(usage.reasoningTokens ?? 0) total=\(usage.totalTokens)"
}

extension Duration {
  fileprivate var milliseconds: Int64 {
    components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
  }
}
