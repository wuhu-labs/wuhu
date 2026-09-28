import CQuickJS
import JSONValue

enum HostFunction {
  case synchronous(@Sendable ([JSONValue]) throws -> JSONValue)
  case promising(@Sendable ([JSONValue]) async throws -> JSONValue, keepsAlive: Bool)
  case cancel
}

struct ScheduledCall: Sendable {
  let id: Int
  let body: @Sendable ([JSONValue]) async throws -> JSONValue
  let arguments: [JSONValue]
  let cancellation: CallCancellation
}

struct HostCompletion: Sendable {
  enum Outcome: Sendable {
    case value(JSONValue)
    case failure(String)
  }

  let id: Int
  let outcome: Outcome
}

struct PendingCall {
  let promise: JSValue
  let resolve: JSValue
  let reject: JSValue
  let keepsAlive: Bool
  let cancellation: CallCancellation
}

struct CallCancellation: Sendable {
  private let stream: AsyncStream<Never>
  private let continuation: AsyncStream<Never>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Never>.makeStream()
  }

  func cancel() { continuation.finish() }

  func wait() async {
    for await _ in stream {}
  }
}

final class EngineState {
  let interrupter: JSEngine.Interrupter
  let stepBudget: Int?
  var steps = 0
  var terminated = false
  var running = false
  var functions: [HostFunction] = []
  var modules: Set<String> = []
  var scheduled: [ScheduledCall] = []
  var pending: [Int: PendingCall] = [:]
  var nextCallID = 0
  var jobError: JSError?

  init(interrupter: JSEngine.Interrupter, stepBudget: Int?) {
    self.interrupter = interrupter
    self.stepBudget = stepBudget
  }

  var keptAlive: Bool { pending.values.contains(where: \.keepsAlive) }

  func beginEntry() {
    steps = 0
    terminated = false
    jobError = nil
  }

  func release(_ call: PendingCall, in ctx: OpaquePointer) {
    JS_FreeValue(ctx, call.promise)
    JS_FreeValue(ctx, call.resolve)
    JS_FreeValue(ctx, call.reject)
  }
}

func interruptHandler(_ runtime: OpaquePointer?, _ opaque: UnsafeMutableRawPointer?) -> Int32 {
  guard let opaque else { return 0 }
  let state = Unmanaged<EngineState>.fromOpaque(opaque).takeUnretainedValue()
  if state.interrupter.flag.load(ordering: .relaxed) {
    state.terminated = true
    return 1
  }
  guard let budget = state.stepBudget else { return 0 }
  state.steps += 1
  if state.steps > budget {
    state.terminated = true
    return 1
  }
  return 0
}

func hostTrampoline(
  _ ctx: OpaquePointer?,
  _ thisValue: JSValue,
  _ argc: Int32,
  _ argv: UnsafeMutablePointer<JSValue>?,
  _ magic: Int32,
  _ functionData: UnsafeMutablePointer<JSValue>?,
) -> JSValue {
  guard let ctx, let opaque = JS_GetContextOpaque(ctx), let functionData else {
    return jsUndefined
  }
  let state = Unmanaged<EngineState>.fromOpaque(opaque).takeUnretainedValue()
  let function = state.functions[Int(functionData[0].u.int32)]
  if case .cancel = function {
    return cancel(argc > 0 ? argv![0] : jsUndefined, reason: argc > 1 ? argv![1] : jsUndefined, state: state, in: ctx)
  }
  var arguments: [JSONValue] = []
  arguments.reserveCapacity(Int(argc))
  do {
    for index in 0 ..< Int(argc) {
      arguments.append(try toJSON(argv![index], in: ctx))
    }
  } catch {
    return throwError(describe(error), in: ctx)
  }
  switch function {
  case .synchronous(let body):
    do {
      return try toJS(body(arguments), in: ctx)
    } catch {
      return throwError(describe(error), in: ctx)
    }
  case .promising(let body, let keepsAlive):
    var resolving = [jsUndefined, jsUndefined]
    let promise = resolving.withUnsafeMutableBufferPointer {
      JS_NewPromiseCapability(ctx, $0.baseAddress)
    }
    if isException(promise) { return promise }
    let id = state.nextCallID
    state.nextCallID += 1
    let cancellation = CallCancellation()
    state.pending[id] = PendingCall(
      promise: JS_DupValue(ctx, promise),
      resolve: resolving[0],
      reject: resolving[1],
      keepsAlive: keepsAlive,
      cancellation: cancellation,
    )
    state.scheduled.append(ScheduledCall(id: id, body: body, arguments: arguments, cancellation: cancellation))
    return promise
  case .cancel:
    preconditionFailure("handled before argument conversion")
  }
}

private func cancel(_ promise: JSValue, reason: JSValue, state: EngineState, in ctx: OpaquePointer) -> JSValue {
  guard case let (id, call)? = state.pending.first(where: { JS_IsSameValue(ctx, $0.value.promise, promise) })
    .map({ ($0.key, $0.value) })
  else { return JS_NewBool(ctx, false) }
  state.pending.removeValue(forKey: id)
  state.scheduled.removeAll { $0.id == id }
  call.cancellation.cancel()
  defer { state.release(call, in: ctx) }
  var arguments = [reason]
  let result = arguments.withUnsafeMutableBufferPointer {
    JS_Call(ctx, call.reject, jsUndefined, 1, $0.baseAddress)
  }
  if isException(result) { return result }
  JS_FreeValue(ctx, result)
  return JS_NewBool(ctx, true)
}

func describe(_ error: any Error) -> String {
  if let jsError = error as? JSError, case .exception(let message, _) = jsError {
    return message
  }
  return String(describing: error)
}
