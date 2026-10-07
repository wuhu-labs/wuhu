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

public enum InferenceMode: Hashable, Sendable {
  case normal
  case forcedCompact
}

public struct CompletedInference: Sendable {
  public var message: AssistantMessage
  public var metadata: AssistantMessageMetadata

  public init(message: AssistantMessage, metadata: AssistantMessageMetadata) {
    self.message = message
    self.metadata = metadata
  }
}

public struct InferenceCancelled: Error, Equatable, Sendable {}

public struct InferenceExecutor: Sendable {
  public var session: SessionID
  public var model: ResolvedModel
  public var systemPrompt: String
  public var tools: [Tool]
  public var thresholds: CompactionThresholds
  public var compactToolName: String
  public var hub: AttemptHub?
  public var log: AttemptLogConfig?
  public var metrics: InferenceMetricsSink
  public var webSocket: ResponsesWebSocketSession?
  public var receiveQuota: @Sendable (JSONValue) async -> Void
  public var mediaResolver: (@Sendable (ImageLimits) -> any MediaResolver)?

  public init(
    session: SessionID,
    model: ResolvedModel,
    systemPrompt: String,
    tools: [Tool],
    thresholds: CompactionThresholds = .init(),
    compactToolName: String = "compact",
    hub: AttemptHub? = nil,
    log: AttemptLogConfig? = nil,
    metrics: InferenceMetricsSink = .noop,
    webSocket: ResponsesWebSocketSession? = nil,
    receiveQuota: @escaping @Sendable (JSONValue) async -> Void = { _ in },
    mediaResolver: (@Sendable (ImageLimits) -> any MediaResolver)? = nil,
  ) {
    self.session = session
    self.model = model
    self.systemPrompt = systemPrompt
    self.tools = tools
    self.thresholds = thresholds
    self.compactToolName = compactToolName
    self.hub = hub
    self.log = log
    self.metrics = metrics
    self.mediaResolver = mediaResolver
    self.webSocket = webSocket
    self.receiveQuota = receiveQuota
  }

  public func run(
    attemptID: UUID,
    transcript: Transcript,
    mode: InferenceMode,
    idleTimeout: Duration? = nil,
    handles: [String: String] = [:],
    devices: [String: String] = [:],
  ) async throws -> CompletedInference {
    let context = await transcript.renderRequest(
      session: session,
      systemPrompt: systemPrompt,
      tools: tools,
      budget: model.budget,
      thresholds: thresholds,
      handles: handles,
      devices: devices,
    )
    var options = RequestOptions(
      maxTokens: model.budget.maxOutput,
      reasoning: .effort(model.specifier.effort),
      idleTimeout: idleTimeout,
    )
    if mode == .forcedCompact {
      // Cache discipline: the tool list stays byte-identical on a forced turn;
      // only tool_choice (and, per dialect, thinking) vary.
      options.toolChoice = .tool(name: compactToolName)
    }

    let sizes = TrafficSizes()
    var endpoint: any ModelEndpoint = model.endpoint
    if model.transport == .websocket {
      guard let webSocket, let responses = endpoint as? any ResponsesEndpoint else {
        throw InferenceError.invalidInput(status: 422, body: "WebSocket transport has no runtime session")
      }
      endpoint = responses.withWebSocket(session: webSocket, attemptID: attemptID.uuidString, observer: try socketAttemptObserver(file: log?.fileURL(attemptID: attemptID), sizes: sizes), receiveQuota: receiveQuota)
    } else if let log {
      @Dependency(\.fetch) var fetch
      endpoint = endpoint.withFetch(attemptLoggingFetch(
        base: fetch,
        file: log.fileURL(attemptID: attemptID),
        sizes: sizes,
      ))
    }
    if let mediaResolver {
      endpoint = endpoint.withMediaResolver(mediaResolver(model.budget.images.forRequest(imageCount: context.imageCount)))
    }

    @Dependency(\.continuousClock) var continuousClock
    @Dependency(\.date) var dateGen

    hub?.publish(session: session, .started(attemptID: attemptID))
    let timestamp = dateGen.now
    var completed: CompletedInference?
    var failure: InferenceError?
    var reportedUsage: Usage?
    var servedModel: String?
    var firstEventSeen = false

    func handle(_ result: Result<InferenceEvent, InferenceError>) {
      switch result {
      case let .success(event):
        if case let .usage(usage, reportedModel, _) = event {
          reportedUsage = usage
          servedModel = reportedModel
        }
        hub?.publish(session: session, .delta(attemptID: attemptID, event: event))
        if case let .done(message, metadata) = event {
          completed = CompletedInference(message: message, metadata: metadata)
        }
      case let .failure(error):
        failure = error
      }
    }

    var iterator = endpoint.runInference(context: context, options: options, mediaResolver: nil).makeAsyncIterator()
    let clock = AnyClock(continuousClock)
    let started = clock.now
    let firstResult = await iterator.next()
    let ttftDuration = started.duration(to: clock.now)
    if let firstResult {
      if case .success = firstResult { firstEventSeen = true }
      handle(firstResult)
    }
    while failure == nil, let result = await iterator.next() {
      handle(result)
    }
    let elapsed = started.duration(to: clock.now)
    let ttft = firstEventSeen ? ttftDuration : nil

    if let failure {
      hub?.publish(session: session, .finished(
        attemptID: attemptID,
        outcome: .failed(reason: String(describing: failure)),
      ))
      logAttempt(attemptID: attemptID, mode: mode, sizes: sizes, status: "failed(\(failure))", usage: nil, elapsed: elapsed)
      await metrics.record(metric(timestamp: timestamp, error: failure, cancelled: false, usage: reportedUsage, servedModel: servedModel, ttft: ttft, elapsed: elapsed))
      throw failure
    }
    guard let completed else {
      hub?.publish(session: session, .finished(attemptID: attemptID, outcome: .failed(reason: "cancelled")))
      logAttempt(attemptID: attemptID, mode: mode, sizes: sizes, status: "cancelled", usage: nil, elapsed: elapsed)
      await metrics.record(metric(timestamp: timestamp, error: nil, cancelled: true, usage: reportedUsage, servedModel: servedModel, ttft: ttft, elapsed: elapsed))
      throw InferenceCancelled()
    }
    hub?.publish(session: session, .finished(
      attemptID: attemptID,
      outcome: .done(completed.message, completed.metadata),
    ))
    logAttempt(
      attemptID: attemptID,
      mode: mode,
      sizes: sizes,
      status: "done(\(completed.metadata.stopReason.rawValue))",
      usage: completed.metadata.usage,
      elapsed: elapsed,
    )
    await metrics.record(metric(timestamp: timestamp, error: nil, cancelled: false, usage: completed.metadata.usage, servedModel: completed.metadata.servedModel, ttft: ttft, elapsed: elapsed))
    return completed
  }

  public func acknowledge(entry: AssistantEntry, transcript: Transcript, handles: [String: String] = [:], devices: [String: String] = [:]) async {
    guard let webSocket, model.transport == .websocket else { return }
    let context = await transcript.renderRequest(session: session, systemPrompt: systemPrompt, tools: tools, budget: model.budget, thresholds: thresholds, handles: handles, devices: devices)
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
    let derived = cancelled ? (outcome: InferenceMetric.Outcome.cancelled, kind: String?.none, status: Int?.none) : InferenceMetric.classify(error)
    return InferenceMetric(
      timestamp: timestamp,
      session: session,
      provider: model.specifier.provider,
      model: model.specifier.model,
      servedModel: servedModel,
      effort: model.specifier.effort,
      outcome: derived.outcome,
      errorKind: derived.kind,
      status: derived.status,
      ttftMs: ttft?.milliseconds,
      durationMs: elapsed.milliseconds,
      usage: usage,
    )
  }

  private func logAttempt(
    attemptID: UUID,
    mode: InferenceMode,
    sizes: TrafficSizes,
    status: String,
    usage: Usage?,
    elapsed: Duration,
  ) {
    guard log != nil else { return }
    let logger = Logger(label: "wuhu.inference")
    logger.info("inference attempt", metadata: [
      "attempt": "\(attemptID.uuidString.lowercased())",
      "session": "\(session.rawValue)",
      "provider": "\(model.specifier.provider)",
      "model": "\(model.specifier.model)",
      "effort": "\(model.specifier.effort)",
      "mode": "\(mode)",
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

extension Context {
  fileprivate var imageCount: Int {
    messages.reduce(0) { count, message in
      let blocks = switch message {
      case let .user(user): user.content
      case let .assistant(assistant): assistant.content
      case let .toolResult(result): result.content
      }
      return count + blocks.count { if case .media = $0 { true } else { false } }
    }
  }
}
