import struct SessionDomain.RequestID
import struct SessionDomain.SessionID
import struct SessionDomain.SubscriptionID
import struct SpaceContract.GroupID
import Tracing

/// The closed set of span attributes: GenAI semantic-convention names where one exists, `wuhu.*` for the rest. Values are numbers,
/// typed ids or words from a fixed vocabulary.
public struct SpanKey<Value>: Sendable {
  let name: String
  let attribute: @Sendable (Value) -> SpanAttribute
}

extension SpanKey where Value: RawRepresentable<String> & SendableMetatype {
  fileprivate init(_ name: String) { self.init(name: name) { .string($0.rawValue) } }
}

extension SpanKey where Value == SessionID {
  public static var session: Self { .init("wuhu.session.id") }
}

extension SpanKey where Value == GroupID { public static var group: Self { .init("wuhu.group.id") } }
extension SpanKey where Value == RequestID { public static var requestID: Self { .init("wuhu.request.id") } }
extension SpanKey where Value == SubscriptionID { public static var subscription: Self { .init("wuhu.subscription.id") } }

extension SpanKey where Value == String {
  private init(_ name: String) { self.init(name: name) { .string($0) } }
  public static var provider: Self { .init("gen_ai.provider.name") }
  public static var requestModel: Self { .init("gen_ai.request.model") }
  public static var responseModel: Self { .init("gen_ai.response.model") }
  public static var effort: Self { .init("wuhu.effort") }
  public static var modelGroup: Self { .init("wuhu.model_group") }
  public static var transport: Self { .init("wuhu.transport") }
  public static var finishReason: Self { .init("gen_ai.response.finish_reason") }
  public static var inferenceID: Self { .init("wuhu.inference.id") }
  public static var tool: Self { .init("gen_ai.tool.name") }
  public static var toolCallID: Self { .init("gen_ai.tool.call.id") }
  public static var sourceSHA256: Self { .init("wuhu.script.source.sha256") }
  public static var firing: Self { .init("wuhu.firing.id") }
  public static var observer: Self { .init("wuhu.observer") }
  static var machine: Self { .init("wuhu.machine") }
}

extension SpanKey where Value == Int {
  private init(_ name: String) { self.init(name: name) { .int64(Int64($0)) } }
  public static var generation: Self { .init("wuhu.generation") }
  public static var toolCalls: Self { .init("wuhu.tool_calls") }
  public static var attempts: Self { .init("wuhu.attempts") }
  public static var inputTokens: Self { .init("gen_ai.usage.input_tokens") }
  public static var outputTokens: Self { .init("gen_ai.usage.output_tokens") }
  public static var cacheReadTokens: Self { .init("gen_ai.usage.cache_read.input_tokens") }
  public static var cacheCreationTokens: Self { .init("gen_ai.usage.cache_creation.input_tokens") }
  public static var reasoningTokens: Self { .init("wuhu.usage.reasoning_tokens") }
  public static var cacheExpectedTokens: Self { .init("wuhu.cache.expected_tokens") }
  public static var cacheIdleMs: Self { .init("wuhu.cache.idle_ms") }
  public static var ttftMs: Self { .init("wuhu.ttft_ms") }
  public static var httpStatus: Self { .init("http.response.status_code") }
  public static var updates: Self { .init("wuhu.updates") }
  public static var lagMs: Self { .init("wuhu.lag_ms") }
  public static var wakes: Self { .init("wuhu.wakes") }
}

extension SpanKey where Value == Bool {
  public static var running: Self { .init(name: "wuhu.running") { .bool($0) } }
}

/// `error.type` takes a typed error code, never a string a peer sent.
extension SpanKey where Value: RawRepresentable<String> & SendableMetatype {
  public static var errorType: Self { .init("error.type") }
}

extension SpanKey where Value: SpanOutcome { static var outcome: Self { .init("wuhu.outcome") } }
extension SpanKey where Value == ScriptSpanKind { public static var scriptKind: Self { .init("wuhu.script.kind") } }
extension SpanKey where Value == FiringKind { public static var firingKind: Self { .init("wuhu.firing.kind") } }

/// How a span ended, as its `wuhu.outcome`: each span name has its own closed set.
public protocol SpanOutcome: RawRepresentable<String>, Sendable {
  /// What a span whose body throws concludes, unless it concluded first.
  static var errored: Self { get }
  static var cancelled: Self { get }
  var isFailure: Bool { get }
}

/// `tool.call` and `handler.firing`.
public enum StepOutcome: String, SpanOutcome {
  case ok, errored, cancelled
  public var isFailure: Bool { self == .errored }
}

public enum ModelAttemptOutcome: String, SpanOutcome {
  case ok, errored, cancelled, handoff
  public var isFailure: Bool { self == .errored }
}

public enum ScriptOutcome: String, SpanOutcome {
  case released, failed, killed
  public static var errored: Self { .failed }
  public static var cancelled: Self { .killed }
  public var isFailure: Bool { self != .released }
}

public enum ScriptSpanKind: String, Sendable { case call = "run_script", command = "wuhu_script", handler }

public enum FiringKind: String, Sendable { case observe, timer, stream }
