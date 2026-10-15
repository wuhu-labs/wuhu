#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Synchronization

public enum SpanAttribute: String, Codable, Sendable {
  case session = "session.id", group = "group.id", provider, model, effort, outcome
  case ttftMs = "ttft_ms", inputTokens = "tokens.input", outputTokens = "tokens.output"
  case cacheReadTokens = "tokens.cache_read", cacheWriteTokens = "tokens.cache_write", reasoningTokens = "tokens.reasoning"
  case tool = "tool.name", errorCode = "error.code", bytesIn = "bytes.in", bytesOut = "bytes.out"
  case count
  case machineReference = "machine.reference", machine = "machine.id", version = "machine.version", kind, exitCode = "exit.code", verdict
}

public struct TraceContext: Codable, Equatable, Sendable {
  public let traceID: String
  public let spanID: String
  public let session: String
  public let group: String

  init(traceID: String, spanID: String, session: String, group: String) {
    self.traceID = traceID; self.spanID = spanID; self.session = session; self.group = group
  }
}

public enum SpanName: String, Codable, Sendable {
  case turn = "agent.turn", inference = "inference", tool = "tool.call"
  case executionWorkerFence = "execution-worker.boot-fence"
  case machine = "machine.operation", script = "script.run"
}

public struct FinishedSpan: Codable, Equatable, Sendable {
  public let name: SpanName
  public let context: TraceContext
  public let parentSpanID: String?
  public let start: Date
  public let end: Date
  public let attributes: [SpanAttribute: String]
}

public struct ServerSpan: Sendable {
  public let context: TraceContext?
  private let name: SpanName
  private let parent: String?
  private let start: Date
  private let emit: (@Sendable (FinishedSpan) -> Void)?

  public init(_ name: SpanName, session: String? = nil, group: String? = nil, start: Date = Date()) {
    self.name = name; self.start = start
    emit = ServerTracing.emitter ?? ServerTracing.installed.withLock { $0 }
    let held = ServerTracing.context
    parent = held?.spanID
    context = emit == nil ? nil : TraceContext(
      traceID: held?.traceID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      spanID: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased(),
      session: session ?? held?.session ?? "", group: group ?? held?.group ?? "",
    )
  }

  public func finish(_ attributes: [SpanAttribute: String] = [:], end: Date = Date()) {
    guard let context else { return }
    emit?(FinishedSpan(name: name, context: context, parentSpanID: parent, start: start, end: end, attributes: attributes.mapValues { String($0.prefix(256)) }))
  }
}

public enum ServerTracing {
  @TaskLocal public static var context: TraceContext?
  @TaskLocal public static var emitter: (@Sendable (FinishedSpan) -> Void)?
  static let installed = Mutex<(@Sendable (FinishedSpan) -> Void)?>(nil)

  public static func emit(_ span: FinishedSpan) {
    let sink = emitter ?? installed.withLock { $0 }
    sink?(span)
  }

  public static var enabled: Bool { emitter != nil || installed.withLock { $0 != nil } }

  public static func install(_ emit: (@Sendable (FinishedSpan) -> Void)?) {
    installed.withLock { $0 = emit }
  }
}
