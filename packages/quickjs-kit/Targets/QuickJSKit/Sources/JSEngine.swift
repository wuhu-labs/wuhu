import CQuickJS
import JSONValue

public final class JSEngine {
  public let interrupter: Interrupter

  let limits: Limits
  let runtime: OpaquePointer
  let context: OpaquePointer
  let state: EngineState

  public init(limits: Limits = Limits(), interrupter: Interrupter = Interrupter()) {
    guard let runtime = JS_NewRuntime(), let context = JS_NewContext(runtime) else {
      fatalError("QuickJS runtime allocation failed")
    }
    self.runtime = runtime
    self.context = context
    self.interrupter = interrupter
    self.limits = limits
    self.state = EngineState(interrupter: interrupter, stepBudget: limits.stepBudget)

    if let memoryBytes = limits.memoryBytes { JS_SetMemoryLimit(runtime, memoryBytes) }
    JS_SetMaxStackSize(runtime, limits.stackBytes)
    let opaque = Unmanaged.passUnretained(state).toOpaque()
    JS_SetContextOpaque(context, opaque)
    JS_SetInterruptHandler(runtime, interruptHandler, opaque)
  }

  deinit {
    for call in state.pending.values {
      state.release(call, in: context)
    }
    JS_FreeContext(context)
    JS_FreeRuntime(runtime)
  }

  public func define(
    _ name: String,
    _ body: @escaping @Sendable ([JSONValue]) throws -> JSONValue,
  ) {
    install(name, .synchronous(body))
  }

  public func define(
    _ name: String,
    keepsAlive: Bool = true,
    promising body: @escaping @Sendable ([JSONValue]) async throws -> JSONValue,
  ) {
    install(name, .promising(body, keepsAlive: keepsAlive))
  }

  public func defineCancel(_ name: String) {
    install(name, .cancel)
  }

  public func evaluate(_ source: String, name: String = "<evaluate>") throws -> JSONValue {
    state.beginEntry()
    let result = try eval(source, name: name, flags: JS_EVAL_TYPE_GLOBAL)
    defer { JS_FreeValue(context, result) }
    return try toJSON(result, in: context)
  }

  public func execute(_ source: String, name: String = "<execute>") throws {
    state.beginEntry()
    JS_FreeValue(context, try eval(source, name: name, flags: JS_EVAL_TYPE_GLOBAL))
  }

  public func run(_ source: String, name: String = "<run>") async throws -> JSONValue {
    precondition(!state.running, "JSEngine.run is not reentrant")
    state.running = true
    defer { state.running = false }
    state.beginEntry()
    let promise = try eval(
      source, name: name, flags: JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC,
    )
    defer { JS_FreeValue(context, promise) }
    try await drive()
    JS_UpdateStackTop(runtime)
    switch JS_PromiseState(context, promise) {
    case JS_PROMISE_FULFILLED:
      // JS_EVAL_FLAG_ASYNC fulfills with a `{ value }` wrapper around the
      // script's completion value.
      let wrapper = JS_PromiseResult(context, promise)
      defer { JS_FreeValue(context, wrapper) }
      let value = JS_GetPropertyStr(context, wrapper, "value")
      defer { JS_FreeValue(context, value) }
      return try toJSON(value, in: context)
    case JS_PROMISE_REJECTED:
      throw rejection(of: promise)
    default:
      throw state.jobError ?? .stalled
    }
  }

  private func install(_ name: String, _ function: HostFunction) {
    let id = state.functions.count
    state.functions.append(function)
    var data = [JS_NewInt32(context, Int32(id))]
    let value = data.withUnsafeMutableBufferPointer {
      JS_NewCFunctionData(context, hostTrampoline, 0, 0, 1, $0.baseAddress)
    }
    JS_FreeValue(context, data[0])
    let global = JS_GetGlobalObject(context)
    defer { JS_FreeValue(context, global) }
    let stored = name.withCString { JS_SetPropertyStr(context, global, $0, value) }
    precondition(stored >= 0, "defining \(name) on globalThis failed")
  }

  func eval(_ source: String, name: String, flags: Int32) throws -> JSValue {
    let result = evaluateSource(source, name: name, flags: flags, in: context)
    guard !isException(result) else {
      JS_FreeValue(context, result)
      throw failure()
    }
    return result
  }

  func failure() -> JSError {
    state.terminated ? .terminated : pendingException(in: context)
  }

  func rejection(of promise: JSValue) -> JSError {
    JS_UpdateStackTop(runtime)
    let reason = JS_PromiseResult(context, promise)
    defer { JS_FreeValue(context, reason) }
    return exception(reason, in: context)
  }

  // Runs until no call that keeps the run alive is pending, or `finished`
  // holds. Calls that do not keep it alive are cancelled on the way out and
  // their promises never settle.
  func drive(until finished: () -> Bool = { false }) async throws {
    defer {
      for call in state.pending.values {
        state.release(call, in: context)
      }
      state.pending.removeAll()
    }
    try await withThrowingTaskGroup(of: HostCompletion.self) { group in
      defer { group.cancelAll() }
      try pump(into: &group)
      while state.keptAlive, !finished() {
        guard let completion = try await group.next() else { break }
        if interrupter.flag.load(ordering: .relaxed) { throw JSError.terminated }
        try Task.checkCancellation()
        try settle(completion)
        try pump(into: &group)
      }
    }
  }

  private func pump(into group: inout ThrowingTaskGroup<HostCompletion, any Error>) throws {
    try drainJobs()
    let scheduled = state.scheduled
    state.scheduled.removeAll(keepingCapacity: true)
    for call in scheduled {
      group.addTask { await perform(call) }
    }
  }

  func drainJobs() throws {
    JS_UpdateStackTop(runtime)
    while JS_IsJobPending(runtime) {
      var jobContext: OpaquePointer?
      let status = JS_ExecutePendingJob(runtime, &jobContext)
      if state.terminated { throw JSError.terminated }
      if status < 0, let jobContext, state.jobError == nil {
        state.jobError = pendingException(in: jobContext)
      }
      if status == 0 { break }
    }
  }

  private func settle(_ completion: HostCompletion) throws {
    guard let call = state.pending.removeValue(forKey: completion.id) else { return }
    JS_UpdateStackTop(runtime)
    defer { state.release(call, in: context) }
    let argument: JSValue
    let settler: JSValue
    switch completion.outcome {
    case .value(let value):
      argument = try toJS(value, in: context)
      settler = call.resolve
    case .failure(let message):
      let error = JS_NewError(context)
      var bytes = message.utf8CString
      let text = bytes.withUnsafeMutableBufferPointer {
        JS_NewStringLen(context, $0.baseAddress, $0.count - 1)
      }
      _ = "message".withCString { JS_SetPropertyStr(context, error, $0, text) }
      argument = error
      settler = call.reject
    }
    var arguments = [argument]
    let result = arguments.withUnsafeMutableBufferPointer {
      JS_Call(context, settler, jsUndefined, 1, $0.baseAddress)
    }
    JS_FreeValue(context, argument)
    if isException(result) { throw failure() }
    JS_FreeValue(context, result)
  }
}

func evaluateSource(_ source: String, name: String, flags: Int32, in ctx: OpaquePointer) -> JSValue {
  JS_UpdateStackTop(JS_GetRuntime(ctx))
  var bytes = source.utf8CString
  return bytes.withUnsafeMutableBufferPointer { buffer in
    name.withCString { file in
      JS_Eval(ctx, buffer.baseAddress, buffer.count - 1, file, flags)
    }
  }
}

private func perform(_ call: ScheduledCall) async -> HostCompletion {
  let outcome = await withTaskGroup(of: HostCompletion.Outcome?.self) { race in
    race.addTask {
      do {
        return .value(try await call.body(call.arguments))
      } catch {
        return .failure(describe(error))
      }
    }
    race.addTask {
      await call.cancellation.wait()
      return nil
    }
    let first = await race.next() ?? nil
    race.cancelAll()
    return first
  }
  return HostCompletion(id: call.id, outcome: outcome ?? .failure("cancelled"))
}
