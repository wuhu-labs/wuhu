import func MainHub.resolveScriptModule
import struct MainHub.ScriptError
import struct MainHub.ScriptHandlerInvocation
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
    var stateJSON: String?
    var wakes: [String] = []
    var wakeBytes = 0
  }

  let input: JSONValue
  private let output = Mutex(Output())

  init(rows: Rows?, fireTime: Date?, stateJSON: String?) throws {
    var fields: OrderedDictionary<String, JSONValue> = ["state": .null]
    if let stateJSON {
      guard let state = JSONValue.parse(stateJSON) else { throw ScriptError("invalid saved handler state") }
      fields["state"] = state
    }
    if let rows, case let .object(snapshot) = Wire.queryOutput(rows), case let .array(values)? = snapshot["rows"] {
      fields["rows"] = .array(values.map { value in
        guard case let .array(cells) = value else { preconditionFailure("query rows are arrays") }
        var object: OrderedDictionary<String, JSONValue> = [:]
        for (column, cell) in zip(rows.columns, cells) { object[column] = cell }
        return .object(object)
      })
    }
    if let fireTime { fields["fireTime"] = .string(fireTime.ISO8601Format()) }
    input = .object(fields)
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
    engine.define("__handler_return") { [self] args in
      let json = string(args, 0)
      guard json.utf8.count <= 16 << 10 else { throw ScriptError("handler state exceeds 16 KiB") }
      guard JSONValue.parse(json) != nil else { throw ScriptError("handler returned invalid JSON state") }
      self.output.withLock { $0.stateJSON = json }
      return .null
    }
    try engine.execute("""
    (() => {
      const input = __handler_input(), wakeHost = __handler_wake, returned = __handler_return;
      delete globalThis.__handler_input; delete globalThis.__handler_wake; delete globalThis.__handler_return;
      globalThis.wake = (text) => wakeHost(String(text));
      globalThis.__handler_invoke = async (handler) => {
        if (typeof handler !== 'function') throw new TypeError('handler module must export a default function');
        const state = await handler({...input, wake: globalThis.wake});
        const json = JSON.stringify(state);
        if (json === undefined) throw new TypeError('handler must return JSON state (use null for no state)');
        returned(json);
      };
    })();
    """, name: "<handler>")
  }

  func result() throws -> ScriptHandlerResult {
    try self.output.withLock {
      guard let stateJSON = $0.stateJSON else { throw ScriptError("handler did not return JSON state") }
      return ScriptHandlerResult(stateJSON: stateJSON, wakes: $0.wakes)
    }
  }
}

extension Scripts {
  public func runHandler(
    id: UUID = UUID(),
    path: String,
    actor: ScriptActor,
    rows: Rows? = nil,
    fireTime: Date? = nil,
    stateJSON: String? = nil,
    tools: ToolExecutor,
  ) async throws -> ScriptHandlerResult {
    let context = try ScriptHandlerContext(rows: rows, fireTime: fireTime, stateJSON: stateJSON)
    let module = try resolveScriptModule(path.hasPrefix("/") ? "wuhu:" + path : path, from: "script")
    let quoted = JSONValue.string(module).jsonString()
    let client = try await tools.client(actor)
    let execution = ScriptExecution(
      id: ScriptHandlerInvocation.scriptID(id),
      actor: actor,
      source: "import handler from \(quoted); await __handler_invoke(handler); delete globalThis.__handler_invoke;",
      lifetime: .seconds(60),
      client: client,
      secrets: ScriptSecrets(client: client),
      tools: tools,
      kind: .handler(context),
    )
    await execution.run(owner: owner)
    let result = try execution.handlerResult()
    return result
  }
}
