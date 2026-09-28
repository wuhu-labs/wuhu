#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import QuickJSKit
import SessionDomain
import SpaceCore
import SpaceTools

// The data half of `wuhu:space`: the JS core pages share, over a
// transport of host calls that act as the session. Each call answers
// `{ok: value}` or `{error: payload}`, so the core raises a SpaceError with the
// code, hint and token a page would see.
struct ScriptSpace: Sendable {
  let execution: ScriptExecution
  let space: Space
  let streams = ScriptStreams()

  private var session: SessionID {
    execution.session
  }

  func install(in engine: JSEngine) {
    engine.define("__wuhu_space_query", promising: { arguments in
      await answer {
        let room = execution.buffers.withLock(\.room)
        let rows: Rows
        do {
          rows = try await space.query(
            string(arguments, 0), parameters: array(arguments, 1), byteLimit: room, as: try await principal(),
          )
        } catch SpaceError.queryResultTooLarge {
          throw overBudget(.queryResult)
        }
        return Wire.typedQueryOutput(rows)
      }
    })
    engine.define("__wuhu_space_open", promising: { arguments in
      await answer {
        switch string(arguments, 0) {
        case "observe": try await openObserve(string(arguments, 1), parameters: array(arguments, 2))
        case "watch": try await openWatch(string(arguments, 1), from: arguments[safe: 2])
        default: throw ScriptError("unknown stream")
        }
      }
    })
    engine.define("__wuhu_space_next", promising: { arguments in
      await answer { try await streams.next(id(arguments)) ?? .null }
    })
    engine.define("__wuhu_space_close", keepsAlive: false, promising: { arguments in
      await streams.close(id(arguments))
      return .null
    })
    engine.define("__wuhu_space_rows", promising: { arguments in
      await answer {
        let principal = try await principal()
        let path = try scriptWritable(string(arguments, 0), by: session, as: principal)
        let edits = try RowEdit.parse(arguments[safe: 1] ?? .null)
        let commit = try await SpaceToolContext(space: space, principal: principal).commitRows(path, edits: edits)
        return .object(["rev": .integer(commit.rev.value), "ids": .array(commit.ids.map { .integer(Int($0)) })])
      }
    })
    engine.define("__wuhu_space_attributes", promising: { arguments in
      await answer {
        try await run("attributes.read", ["path": .string(string(arguments, 0))], as: try await principal())
      }
    })
    engine.define("__wuhu_space_patch", promising: { arguments in
      await answer {
        let principal = try await principal()
        let path = try scriptWritable(string(arguments, 0), by: session, as: principal)
        guard case var .object(input)? = arguments[safe: 1] else { throw ScriptError("malformed patch") }
        input["path"] = .string(path)
        return try await run("attributes.patch", .object(input), as: principal)
      }
    })
  }

  private func principal() async throws -> Principal {
    try await space.principal(of: session)
  }

  private func openObserve(_ sql: String, parameters: [JSONValue]) async throws -> JSONValue {
    let principal = try await principal()
    _ = try Space.bound(parameters)
    try await space.validateQuery(sql, as: principal)
    let snapshots = await space.observeQuery(sql, parameters: parameters, throttle: .zero, as: principal)
    return .integer(await streams.open(snapshots, newestOnly: true) { Wire.typedQueryOutput($0) })
  }

  private func openWatch(_ glob: String, from: JSONValue?) async throws -> JSONValue {
    guard !glob.isEmpty else { throw ToolRunError.failed(code: .invalidArgument, message: "watch takes a glob", hint: nil) }
    let start: Rev? = switch from {
    case let .integer(rev)? where rev >= 0: Rev(rev)
    case nil, .null?: nil
    default: throw ToolRunError.failed(code: .invalidArgument, message: "from must be a non-negative revision", hint: nil)
    }
    let watched = try await WatchedGlob(glob, as: try await principal(), in: space)
    let events = await space.observeFS(glob: watched.pattern, from: start, group: watched.group)
    return .integer(await streams.open(events, newestOnly: false) { Wire.mutationJSON($0, prefix: watched.prefix) })
  }

  private func run(_ name: String, _ input: JSONValue, as principal: Principal) async throws -> JSONValue {
    try await SpaceToolbox.all.first { $0.name == name }!.run(SpaceToolContext(space: space, principal: principal), input: input)
  }
}

/// A budget or protocol failure stays a plain error; a space failure becomes
/// the payload the core turns into a SpaceError.
private func answer(_ body: () async throws -> JSONValue) async -> JSONValue {
  do {
    return .object(["ok": try await body()])
  } catch let error as ScriptError {
    return .object(["error": ToolRunError.failed(code: .invalidArgument, message: error.description, hint: nil).payload])
  } catch {
    return .object(["error": Wire.failure(error).payload])
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
  private var last = 0
  private var reading: [Int: AsyncThrowingStream<JSONValue, any Error>.AsyncIterator] = [:]
  private var pending: Set<Int> = []
  private var closing: Set<Int> = []

  func open<Source: AsyncSequence & Sendable>(
    _ source: Source, newestOnly: Bool, render: @escaping @Sendable (Source.Element) -> JSONValue,
  ) -> Int where Source.Element: Sendable {
    let stream = AsyncThrowingStream<JSONValue, any Error>(bufferingPolicy: newestOnly ? .bufferingNewest(1) : .unbounded) { continuation in
      let pump = Task {
        do {
          for try await element in source {
            continuation.yield(render(element))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in pump.cancel() }
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
    export const createSpace = () => ({ query: missing, observe: missing, watch: missing, mutateRows: missing, readAttributes: missing, patchAttributes: missing })
    export const failure = missing
    """
  #endif
}()
