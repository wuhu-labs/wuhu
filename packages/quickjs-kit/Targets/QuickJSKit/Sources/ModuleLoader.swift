import CQuickJS
import JSONValue
import OrderedCollections

extension JSEngine {
  public struct ModuleLoader: Sendable {
    let maxModules: Int
    let resolve: @Sendable (_ specifier: String, _ referrer: String) throws -> String
    let source: @Sendable (_ name: String) async throws -> String

    public init(
      maxModules: Int,
      resolve: @escaping @Sendable (_ specifier: String, _ referrer: String) throws -> String,
      source: @escaping @Sendable (_ name: String) async throws -> String,
    ) {
      self.maxModules = maxModules
      self.resolve = resolve
      self.source = source
    }
  }

  // QuickJS asks for modules synchronously while it compiles, but sources
  // arrive asynchronously. A scratch engine compiles each module against
  // empty stubs to learn what it imports, wave by wave, so the real compile
  // finds every source already fetched.
  func discover(_ source: String, registry: ModuleRegistry) async throws {
    let scratch = JSEngine(limits: limits)
    registry.install(on: scratch.runtime)
    try scratch.compile(source, name: registry.entry, for: registry)
    while registry.discovered.count > registry.fetched {
      let wave = Array(registry.discovered[registry.fetched...])
      registry.fetched = registry.discovered.count
      if registry.discovered.count > registry.loader.maxModules {
        let name = registry.discovered[registry.loader.maxModules]
        throw registry.located("the import graph has more than \(registry.loader.maxModules) modules", at: name)
      }
      let loader = registry.loader
      let results = await withTaskGroup(of: (Int, Result<String, any Error>).self) { group in
        for (index, name) in wave.enumerated() {
          group.addTask {
            // Returning `(index, .success(try await …))` straight from `do` makes
            // Swift 6.3 -O report index 0 for every success, so the result is
            // bound first.
            let result: Result<String, any Error>
            do { result = .success(try await loader.source(name)) } catch { result = .failure(error) }
            return (index, result)
          }
        }
        var results = [Result<String, any Error>?](repeating: nil, count: wave.count)
        for await (index, result) in group { results[index] = result }
        return results
      }
      try Task.checkCancellation()
      for (name, result) in zip(wave, results) {
        switch result! {
        case .success(let text): registry.sources[name] = text
        case .failure(let error): throw registry.located(describe(error), at: name)
        }
      }
      for name in wave {
        try scratch.compile(registry.sources[name]!, name: name, for: registry)
      }
    }
  }

  private func compile(_ source: String, name: String, for registry: ModuleRegistry) throws {
    let compiled = evaluateSource(source, name: name, flags: JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY, in: context)
    guard !isException(compiled) else {
      let error = failure()
      if let failure = registry.failure { throw failure }
      guard name != registry.entry, case .exception(let message, let stack) = error else { throw error }
      throw registry.located(message, at: name, stack: stack)
    }
    JS_FreeValue(context, compiled)
  }
}

final class ModuleRegistry {
  enum Mode { case discovering, linking, closed }

  let entry: String
  let builtins: Set<String>
  let loader: JSEngine.ModuleLoader
  let meta: OrderedDictionary<String, JSONValue>
  var mode = Mode.discovering
  var discovered: [String] = []
  var importers: [String: String] = [:]
  var fetched = 0
  var sources: [String: String] = [:]
  var failure: JSError?

  init(entry: String, builtins: Set<String>, loader: JSEngine.ModuleLoader, meta: OrderedDictionary<String, JSONValue>) {
    self.entry = entry
    self.builtins = builtins
    self.loader = loader
    self.meta = meta
  }

  func install(on runtime: OpaquePointer) {
    JS_SetModuleLoaderFunc(runtime, normalizeModule, loadModule, Unmanaged.passUnretained(self).toOpaque())
  }

  func located(_ message: String, at name: String, stack: String? = nil) -> JSError {
    var chain = [name]
    while let importer = importers[chain.last!] { chain.append(importer) }
    return .exception(message: "\(chain.reversed().joined(separator: " → ")): \(message)", stack: stack)
  }

  func record(_ message: String, at name: String, stack: String? = nil) {
    if failure == nil { failure = located(message, at: name, stack: stack) }
  }
}

private func moduleRegistry(_ opaque: UnsafeMutableRawPointer) -> ModuleRegistry {
  Unmanaged<ModuleRegistry>.fromOpaque(opaque).takeUnretainedValue()
}

private func normalizeModule(
  _ ctx: OpaquePointer?,
  _ base: UnsafePointer<CChar>?,
  _ name: UnsafePointer<CChar>?,
  _ opaque: UnsafeMutableRawPointer?,
) -> UnsafeMutablePointer<CChar>? {
  guard let ctx, let base, let name, let opaque else { return nil }
  let registry = moduleRegistry(opaque)
  let specifier = String(cString: name)
  if registry.mode == .closed {
    _ = throwError("import() is not supported; import '\(specifier)' statically", in: ctx)
    return nil
  }
  if registry.builtins.contains(specifier) { return js_strdup(ctx, name) }
  let referrer = String(cString: base)
  let resolved: String
  do {
    resolved = try registry.loader.resolve(specifier, referrer)
  } catch {
    registry.record(describe(error), at: referrer)
    _ = throwError(describe(error), in: ctx)
    return nil
  }
  if resolved != registry.entry, registry.importers[resolved] == nil {
    precondition(registry.mode == .discovering, "\(resolved) was not discovered before linking")
    registry.importers[resolved] = referrer
    registry.discovered.append(resolved)
  }
  return js_strdup(ctx, resolved)
}

private func loadModule(
  _ ctx: OpaquePointer?,
  _ name: UnsafePointer<CChar>?,
  _ opaque: UnsafeMutableRawPointer?,
) -> OpaquePointer? {
  guard let ctx, let name, let opaque else { return nil }
  let registry = moduleRegistry(opaque)
  let moduleName = String(cString: name)
  let source: String
  switch registry.mode {
  case .discovering:
    source = "export {}"
  case .linking:
    guard let known = registry.sources[moduleName] else {
      preconditionFailure("\(moduleName) was not discovered before linking")
    }
    source = known
  case .closed:
    preconditionFailure("the normalizer refuses every import once the graph is linked")
  }
  let compiled = evaluateSource(source, name: moduleName, flags: JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY, in: ctx)
  if isException(compiled) {
    let thrown = JS_GetException(ctx)
    if case .exception(let message, let stack) = exception(thrown, in: ctx) {
      registry.record(message, at: moduleName, stack: stack)
    }
    _ = JS_Throw(ctx, thrown)
    return nil
  }
  let module = OpaquePointer(compiled.u.ptr)
  JS_FreeValue(ctx, compiled)
  if registry.mode == .linking {
    do {
      try setImportMeta(registry.meta, of: module, in: ctx)
    } catch {
      registry.record(describe(error), at: moduleName)
      _ = throwError(describe(error), in: ctx)
      return nil
    }
  }
  return module
}
