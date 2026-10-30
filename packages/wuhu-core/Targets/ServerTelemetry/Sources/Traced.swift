import Dependencies
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import Synchronization
import Tracing

/// A span's name and the outcomes it concludes with.
public struct SpanName<Outcome: SpanOutcome>: Sendable {
  let rawValue: String
  /// Takes the cache expectation in its context.
  var expectsCache = false
  /// Is named by the first machine reached under it.
  var namesMachine = false
}

extension SpanName where Outcome == StepOutcome {
  public static var turn: Self { .init(rawValue: "agent.turn") }
  public static var tool: Self { .init(rawValue: "tool.call", namesMachine: true) }
  public static var firing: Self { .init(rawValue: "handler.firing") }
  public static var compaction: Self { .init(rawValue: "agent.compaction") }
}

extension SpanName where Outcome == ModelAttemptOutcome { public static var attempt: Self { .init(rawValue: "model.attempt", expectsCache: true) } }
extension SpanName where Outcome == InferenceOutcome { public static var inference: Self { .init(rawValue: "agent.inference") } }
extension SpanName where Outcome == ScriptOutcome { public static var script: Self { .init(rawValue: "script.run") } }

/// Whose work a trace is: set at a root and stamped on every span under it as `wuhu.session.id` and `wuhu.group.id`.
public struct SpanOwner: Hashable, Sendable {
  public let session: SessionID?
  public let group: GroupID

  public init(session: SessionID?, group: GroupID) {
    self.session = session
    self.group = group
  }
}

/// What the session's last successful attempt predicts for the next one's cache, stamped on `model.attempt` spans under it.
public struct CacheExpectation: Hashable, Sendable {
  public let tokens: Int
  public let idleMs: Int

  public init(tokens: Int, idleMs: Int) {
    self.tokens = tokens
    self.idleMs = idleMs
  }
}

private enum OwnerKey: ServiceContextKey { typealias Value = SpanOwner }
private enum CacheKey: ServiceContextKey { typealias Value = CacheExpectation }
private enum MachineKey: ServiceContextKey { typealias Value = MachineSlot }

private final class MachineSlot: Sendable {
  let span: any Span
  let named = Atomic(false)

  init(_ span: any Span) { self.span = span }
}

extension DependencyValues {
  /// `InstrumentationSystem.tracer` unless a test sets one.
  public var tracer: any Tracer {
    get { self[TracerKey.self] ?? InstrumentationSystem.tracer }
    set { self[TracerKey.self] = newValue }
  }
}

private enum TracerKey: DependencyKey {
  static let liveValue: (any Tracer)? = nil
  static let testValue: (any Tracer)? = nil
}

/// Where a span starts: under the span current when this was taken, or at a new trace's root.
public struct TraceParent: Sendable {
  fileprivate var context: ServiceContext

  public static var current: TraceParent { TraceParent(context: .current ?? .topLevel) }

  public static func root(_ owner: SpanOwner) -> TraceParent {
    var context = ServiceContext.topLevel
    context[OwnerKey.self] = owner
    return TraceParent(context: context)
  }

  /// The trace the caller runs in; nil outside one.
  public static var enclosing: TraceParent? { ServiceContext.current.map(TraceParent.init) }

  /// Runs `body` under this parent, starting no span: what `body` traces nests under it.
  public func run<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
    try await ServiceContext.withValue(context) { try await body() }
  }
}

/// Runs `body` outside any trace, for work it starts that must not join the trace of whoever happened to start it.
public func untraced<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
  try await ServiceContext.withValue(nil) { try await body() }
}

/// `tracer`, stamping the owner of the trace each span starts in on it: for code that traces on plain `Tracing`.
public func stampingOwners(_ tracer: some Tracer) -> any Tracer { OwnerStamping(base: tracer) }

private struct OwnerStamping<Base: Tracer>: Tracer {
  let base: Base

  func startSpan<Instant: TracerInstant>(
    _ operationName: String,
    context: @autoclosure () -> ServiceContext,
    ofKind kind: SpanKind,
    at instant: @autoclosure () -> Instant,
    function: String,
    file fileID: String,
    line: UInt,
  ) -> Base.Span {
    let context = context()
    let span = base.startSpan(operationName, context: context, ofKind: kind, at: instant(), function: function, file: fileID, line: line)
    if span.isRecording, let owner = context[OwnerKey.self] {
      var fields = SpanFields()
      fields.set(.session, owner.session)
      fields.set(.group, owner.group)
      span.updateAttributes { $0.merge(fields.attributes) }
    }
    return span
  }

  func activeSpan(identifiedBy context: ServiceContext) -> Base.Span? { base.activeSpan(identifiedBy: context) }
  @available(*, deprecated) func forceFlush() { base.forceFlush() }

  func inject<Carrier, Inject: Injector>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject) where Inject.Carrier == Carrier {
    base.inject(context, into: &carrier, using: injector)
  }

  func extract<Carrier, Extract: Extractor>(_ carrier: Carrier, into context: inout ServiceContext, using extractor: Extract) where Extract.Carrier == Carrier {
    base.extract(carrier, into: &context, using: extractor)
  }
}

/// Runs `body` in a span under `parent`. The span never records the error a body throws, only its outcome: an error's
/// description is content.
public func traced<Outcome, T>(
  _ name: SpanName<Outcome>,
  under parent: TraceParent = .current,
  isolation: isolated (any Actor)? = #isolation,
  _ body: (TelemetrySpan<Outcome>) async throws -> T,
) async rethrows -> T {
  @Dependency(\.tracer) var tracer
  var context = parent.context
  let span = TelemetrySpan<Outcome>(stampingOwners(tracer).startSpan(name.rawValue, context: context))
  defer { span.span.end() }
  if name.expectsCache, let cache = context[CacheKey.self] {
    span.set(.cacheExpectedTokens, cache.tokens)
    span.set(.cacheIdleMs, cache.idleMs)
  }
  context = span.span.context
  if name.namesMachine { context[MachineKey.self] = MachineSlot(span.span) }
  do {
    return try await ServiceContext.withValue(context) { try await body(span) }
  } catch {
    span.conclude(error is CancellationError ? .cancelled : .errored)
    throw error
  }
}

/// Names `machine` as `wuhu.machine` on the `tool.call` span the caller runs under, unless one is named already.
public func reachedMachine(_ machine: some RawRepresentable<String>) {
  guard let slot = ServiceContext.current?[MachineKey.self], slot.span.isRecording, !slot.named.exchange(true, ordering: .relaxed) else { return }
  slot.span.attributes[SpanKey<String>.machine.name] = machine.rawValue
}

/// Runs `body` with `expectation` in the current context, for the `model.attempt` spans it starts.
public func expectingCache<T>(
  _ expectation: CacheExpectation?,
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws -> T,
) async rethrows -> T {
  guard let expectation else { return try await body() }
  var context = ServiceContext.current ?? .topLevel
  context[CacheKey.self] = expectation
  return try await ServiceContext.withValue(context) { try await body() }
}

/// A span that takes only the closed `SpanKey` vocabulary; every write is skipped, value unevaluated, while it does not record.
public final class TelemetrySpan<Outcome: SpanOutcome>: Sendable {
  let span: any Span
  private let concluded = Atomic(false)

  init(_ span: any Span) { self.span = span }

  public var isRecording: Bool { span.isRecording }

  public func set<Value>(_ key: SpanKey<Value>, _ value: @autoclosure () -> Value?) {
    guard span.isRecording, let value = value() else { return }
    span.updateAttributes { $0.set(key.name, value: key.attribute(value)) }
  }

  /// The first conclusion wins, so a body's own outcome survives the error it throws. `providerText`, the provider's error text,
  /// is the one free text a span admits: `exception.message` and the status description.
  public func conclude(_ outcome: Outcome, providerText: String? = nil) {
    guard span.isRecording, !concluded.exchange(true, ordering: .relaxed) else { return }
    set(.outcome, outcome)
    if let providerText { span.updateAttributes { $0.set("exception.message", value: .string(providerText)) } }
    if outcome.isFailure { span.setStatus(.init(code: .error, message: providerText)) }
  }

  public func set(_ fill: (inout SpanFields) -> Void) {
    guard span.isRecording else { return }
    var fields = SpanFields()
    fill(&fields)
    span.updateAttributes { $0.merge(fields.attributes) }
  }

  public func event(_ name: SpanEventName, _ fill: (inout SpanFields) -> Void) {
    guard span.isRecording else { return }
    var fields = SpanFields()
    fill(&fields)
    span.addEvent(SpanEvent(name: name.rawValue, attributes: fields.attributes))
  }
}

public struct SpanFields {
  var attributes = SpanAttributes()

  public mutating func set<Value>(_ key: SpanKey<Value>, _ value: Value?) {
    guard let value else { return }
    attributes.set(key.name, value: key.attribute(value))
  }
}

public enum SpanEventName: String, Sendable {
  case drained = "wuhu.input.drained"
}
