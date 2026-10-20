import struct MainHub.ScriptError
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import QuickJSKit
import SpaceClient
import SpaceCore
import SpaceTools

// The data half of `wuhu:space`: the JS core pages share, over main's API as
// the session. Each call answers `{ok: value}` or `{error: payload}`, so the
// core raises a SpaceError with the code, hint and token a page would see.
struct ScriptSpace: Sendable {
  let execution: ScriptExecution
  let client: SpaceClient
  let streams: ScriptStreams

  func install(in engine: JSEngine) {
    engine.define("__wuhu_space_verb", promising: { arguments in
      await spaceAnswer {
        let name = string(arguments, 0)
        guard ["table.create", "table.schema", "table.alter", "new", "rm", "find", "grep"].contains(name) else {
          throw ToolRunError.failed(code: .invalidArgument, message: "unknown space operation", hint: nil)
        }
        guard case var .object(fields)? = arguments[safe: 1], case let .object(options)? = arguments[safe: 2] else {
          throw ToolRunError.failed(code: .invalidArgument, message: "space operation options must be an object", hint: nil)
        }
        let allowed: Set<String> = switch name {
        case "table.schema": ["rev"]
        case "table.alter": ["ifMatch", "allowDropColumns"]
        case "new": ["in"]
        case "rm": ["ifMatch"]
        default: []
        }
        guard Set(options.keys).isSubset(of: allowed) else {
          throw ToolRunError.failed(code: .invalidArgument, message: "unsupported options for \(name)", hint: nil)
        }
        if let path = fields["path"]?.stringValue { try scriptSpaceAddress(path) }
        for (key, value) in options { fields[key] = value }
        return try await client.tool(name, .object(fields))
      }
    })
    engine.define("__wuhu_space_query", promising: { arguments in
      await spaceAnswer {
        let room = execution.buffers.withLock(\.room)
        let output: JSONValue
        do {
          output = try await client.tool("query", .object([
            "sql": .string(string(arguments, 0)), "parameters": .array(try array(arguments, 1)), "typed": .bool(true), "byteLimit": .integer(room),
          ]))
        } catch let failure as SpaceClient.ToolFailure
          where failure.error.code == .byteLimitExceeded
        {
          throw overBudget(.queryResult)
        }
        return output
      }
    })
    engine.define("__wuhu_space_open", promising: { arguments in
      await spaceAnswer {
        switch string(arguments, 0) {
        case "observe": try await openObserve(string(arguments, 1), parameters: array(arguments, 2))
        case "watch": try await openWatch(string(arguments, 1), from: arguments[safe: 2])
        default: throw ScriptError("unknown stream")
        }
      }
    })
    engine.define("__wuhu_space_next", promising: { arguments in
      await spaceAnswer { try await streams.next(id(arguments)) ?? .null }
    })
    engine.define("__wuhu_space_close", keepsAlive: false, promising: { arguments in
      await streams.close(id(arguments))
      return .null
    })
    engine.define("__wuhu_space_rows", promising: { arguments in
      await spaceAnswer {
        try await client.tool("table.rows", .object(["path": .string(string(arguments, 0)), "ops": arguments[safe: 1] ?? .null]))
      }
    })
    engine.define("__wuhu_space_attributes", promising: { arguments in
      await spaceAnswer {
        try await client.tool("attributes.read", .object(["path": .string(string(arguments, 0))]))
      }
    })
    engine.define("__wuhu_space_patch", promising: { arguments in
      await spaceAnswer {
        guard case var .object(input)? = arguments[safe: 1] else { throw ScriptError("malformed patch") }
        input["path"] = .string(string(arguments, 0))
        return try await client.tool("attributes.patch", .object(input))
      }
    })
  }

  // The route validates the statement before it commits to a stream, so a
  // refusal is the open's error, never a stream that ends at once.
  private func openObserve(_ sql: String, parameters: [JSONValue]) async throws -> JSONValue {
    let snapshots = try await client.observe(ObserveRequest(mode: .sql(sql), parameters: parameters, typed: true))
    return .integer(await streams.open(snapshots, newestOnly: true) { JSONValue.parse($0.data) ?? .null })
  }

  private func openWatch(_ glob: String, from: JSONValue?) async throws -> JSONValue {
    guard !glob.isEmpty else { throw ToolRunError.failed(code: .invalidArgument, message: "watch takes a glob", hint: nil) }
    let start: Int? = switch from {
    case let .integer(rev)? where rev >= 0: rev
    case nil, .null?: nil
    default: throw ToolRunError.failed(code: .invalidArgument, message: "from must be a non-negative revision", hint: nil)
    }
    let events = try await client.observe(ObserveRequest(mode: .glob(glob), from: start))
    return .integer(await streams.open(events, newestOnly: false) { JSONValue.parse($0.data) ?? .null })
  }
}

private func array(_ arguments: [JSONValue], _ index: Int) throws -> [JSONValue] {
  switch arguments[safe: index] {
  case let .array(values)?: values
  case nil, .null?: []
  default: throw ToolRunError.failed(code: .invalidArgument, message: "query parameters must be an array", hint: nil)
  }
}

private func id(_ arguments: [JSONValue]) -> Int {
  guard case let .integer(value)? = arguments.first else { return 0 }
  return value
}

/// The observe and watch streams one execution has open, each read by one
/// `next` at a time; the rest end with the execution.
actor ScriptStreams {
  private let taskScope = TaskScope()
  private var last = 0
  private var reading: [Int: AsyncThrowingStream<JSONValue, any Error>.AsyncIterator] = [:]
  private var pending: Set<Int> = []
  private var closing: Set<Int> = []

  func shutdown() async {
    reading.removeAll()
    closing.formUnion(pending)
    await taskScope.close()
  }

  func open<Source: AsyncSequence & Sendable>(
    _ source: Source, newestOnly: Bool, render: @escaping @Sendable (Source.Element) -> JSONValue,
  ) -> Int where Source.Element: Sendable {
    let stream = AsyncThrowingStream<JSONValue, any Error>(bufferingPolicy: newestOnly ? .bufferingNewest(1) : .unbounded) { continuation in
      let pump = try? taskScope.run("script-stream") {
        do {
          for try await element in source {
            continuation.yield(render(element))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      if pump == nil { continuation.finish(throwing: TaskScopeClosed()) }
      continuation.onTermination = { _ in pump?.cancel() }
    }
    last += 1
    reading[last] = stream.makeAsyncIterator()
    return last
  }

  /// The next item, or nil once the stream ended or was closed.
  func next(_ id: Int) async throws -> JSONValue? {
    guard var iterator = reading.removeValue(forKey: id) else { return nil }
    pending.insert(id)
    defer {
      pending.remove(id)
      closing.remove(id)
    }
    let item = try await iterator.next(isolation: self)
    if item != nil, !closing.contains(id) { reading[id] = iterator }
    return item
  }

  func close(_ id: Int) {
    if reading.removeValue(forKey: id) == nil, pending.contains(id) { closing.insert(id) }
  }
}

/// The JS core `wuhu:space` shares with pages, `space-core.js` in the shell SDK.
let spaceCoreModule: String = {
  #if WUHU_EMBEDDED
    guard let file = EmbeddedShellScripts.files.first(where: { $0.path == ["space-core.js"] }) else {
      preconditionFailure("SessionTools must embed space-core.js")
    }
    return String(decoding: EmbeddedShellScripts.bytes(for: file), as: UTF8.self)
  #else
    return """
    const missing = () => { throw new Error("wuhu:space needs the embedded shell SDK") }
    export const createSpace = () => ({ query: missing, observe: missing, watch: missing, mutateRows: missing, readAttributes: missing, patchAttributes: missing, find: missing, grep: missing })
    export const failure = missing
    """
  #endif
}()
