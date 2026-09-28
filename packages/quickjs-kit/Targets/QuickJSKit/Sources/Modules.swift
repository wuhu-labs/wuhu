import CQuickJS
import JSONValue
import OrderedCollections

extension JSEngine {
  public func defineModule(_ name: String, source: String) throws {
    state.beginEntry()
    let promise = try eval(source, name: name, flags: JS_EVAL_TYPE_MODULE)
    defer { JS_FreeValue(context, promise) }
    state.modules.insert(name)
    try drainJobs()
    switch JS_PromiseState(context, promise) {
    case JS_PROMISE_FULFILLED:
      return
    case JS_PROMISE_REJECTED:
      throw rejection(of: promise)
    default:
      throw state.jobError ?? .stalled
    }
  }

  public func run(
    module source: String,
    name: String = "<module>",
    meta: OrderedDictionary<String, JSONValue> = [:],
    loader: ModuleLoader? = nil,
  ) async throws {
    precondition(!state.running, "JSEngine.run is not reentrant")
    state.running = true
    defer { state.running = false }
    let registry = loader.map { ModuleRegistry(entry: name, builtins: state.modules, loader: $0, meta: meta) }
    if let registry {
      try await discover(source, registry: registry)
      registry.mode = .linking
      registry.install(on: runtime)
    }
    defer {
      if registry != nil { JS_SetModuleLoaderFunc(runtime, nil, nil, nil) }
      withExtendedLifetime(registry) {}
    }
    state.beginEntry()
    let compiled: JSValue
    do {
      compiled = try eval(source, name: name, flags: JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)
    } catch JSError.terminated {
      throw JSError.terminated
    } catch {
      throw registry?.failure ?? error
    }
    registry?.mode = .closed
    do {
      try setImportMeta(meta, of: OpaquePointer(compiled.u.ptr), in: context)
    } catch {
      JS_FreeValue(context, compiled)
      throw error
    }
    JS_UpdateStackTop(runtime)
    let promise = JS_EvalFunction(context, compiled)
    if isException(promise) { throw failure() }
    defer { JS_FreeValue(context, promise) }
    try await drive { JS_PromiseState(context, promise) == JS_PROMISE_REJECTED }
    switch JS_PromiseState(context, promise) {
    case JS_PROMISE_FULFILLED:
      return
    case JS_PROMISE_REJECTED:
      throw rejection(of: promise)
    default:
      throw state.jobError ?? .stalled
    }
  }
}

func setImportMeta(_ meta: OrderedDictionary<String, JSONValue>, of module: OpaquePointer?, in ctx: OpaquePointer) throws {
  let object = JS_GetImportMeta(ctx, module)
  if isException(object) { throw pendingException(in: ctx) }
  defer { JS_FreeValue(ctx, object) }
  for (key, value) in meta {
    let converted = try toJS(value, in: ctx)
    let stored = key.withCString { JS_SetPropertyStr(ctx, object, $0, converted) }
    if stored < 0 { throw pendingException(in: ctx) }
  }
}
