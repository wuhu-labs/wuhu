import func MainHub.handlerScriptID
import func MainHub.resolveScriptModule
import struct MainHub.ScriptError
import struct MainHub.ScriptHandlerResult
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import QuickJSKit
import SessionDomain
import SpaceCore
import SpaceTools
import Synchronization

final class ScriptHandlerContext: Sendable {
  private struct Output {
    var returned = false
    var wakes: [String] = []
    var wakeBytes = 0
  }

  let input: JSONValue
  private let output = Mutex(Output())

  init(input: JSONValue) {
    self.input = input
  }

  func install(in engine: JSEngine) throws {
    engine.define("__handler_input") { [input] _ in input }
    engine.define("__handler_wake") { [self] args in
      let text = string(args, 0)
      try self.output.withLock {
        guard $0.wakes.count < 32, $0.wakeBytes + text.utf8.count <= 64 << 10 else {
          throw ScriptError("handler wake output exceeds 32 messages or 64 KiB")
        }
        $0.wakes.append(text)
        $0.wakeBytes += text.utf8.count
      }
      return .null
    }
    engine.define("__handler_return") { [self] _ in
      self.output.withLock { $0.returned = true }
      return .null
    }
    try engine.execute("""
    (() => {
      const input = __handler_input(), wakeHost = __handler_wake, returned = __handler_return;
      delete globalThis.__handler_input; delete globalThis.__handler_wake; delete globalThis.__handler_return;
      globalThis.wake = (text) => wakeHost(String(text));
      globalThis.__handler_invoke = async (handler) => {
        if (typeof handler !== 'function') throw new TypeError('handler module must export a default function');
        await handler({...input, wake: globalThis.wake});
        returned();
      };
    })();
    """, name: "<handler>")
  }

  func result() throws -> ScriptHandlerResult {
    try self.output.withLock {
      guard $0.returned else { throw ScriptError("handler did not finish") }
      return ScriptHandlerResult(wakes: $0.wakes)
    }
  }
}

extension Scripts {
  public func runHandler(
    id: UUID = UUID(),
    path: String,
    actor: ScriptActor,
    input: JSONValue = .object([:]),
    tools: ToolExecutor,
  ) async throws -> ScriptHandlerResult {
    let context = ScriptHandlerContext(input: input)
    let module = try resolveScriptModule(path.hasPrefix("/") ? "wuhu:" + path : path, from: "script")
    let quoted = JSONValue.string(module).jsonString()
    let client = tools.client(actor)
    let execution = ScriptExecution(
      id: handlerScriptID(id),
      actor: actor,
      source: "import handler from \(quoted); await __handler_invoke(handler); delete globalThis.__handler_invoke;",
      lifetime: .seconds(60),
      client: client,
      secrets: ScriptSecrets(client: client),
      tools: tools,
      kind: .handler(context),
      limits: limits,
    )
    await execution.run()
    let result = try execution.handlerResult()
    return result
  }
}
